import AppKit
import MacTreeCore
import SwiftUI

/// The mosaic, painted rather than composed: a treemap can put thousands of
/// rectangles on screen, and a view per rectangle would spend the frame in
/// layout. Hover and selection rings live on a second canvas, so moving the
/// mouse never repaints the tiles.
struct TreemapView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let tiles = model.tiles(for: geometry.size)
            ZStack {
                MosaicCanvas(tiles: tiles, version: model.treeVersion).equatable()
                RingsCanvas(tiles: tiles, hovered: model.hovered, selected: model.selected)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    model.hovered = hit(tiles, at: point)?.content
                case .ended:
                    model.hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                let content = hit(tiles, at: point)?.content
                // Double-click opens; a tap gesture of count 2 would delay
                // every single click while it waits. Small items open their
                // folder, where they get room of their own.
                if let content, NSApp.currentEvent?.clickCount == 2 {
                    model.open(content.owner)
                } else {
                    model.selected = content
                }
            }
            .overlay {
                // Offscreen rendering draws AppKit views as a placeholder.
                if !Snapshot.isRendering {
                    ContextMenuLayer(model: model, tiles: tiles)
                }
            }
        }
        .background(Palette.background)
    }
}

private struct MosaicCanvas: View, Equatable {
    nonisolated let tiles: [Tile]
    /// Tiles hold references, so equality needs the tree's version too.
    nonisolated let version: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.tiles.count == rhs.tiles.count
            && zip(lhs.tiles, rhs.tiles).allSatisfy { $0.rect == $1.rect }
    }

    var body: some View {
        Canvas { context, _ in
            paintFills(&context)
            paintUnreadable(&context)
            for tile in tiles {
                paintLabel(&context, tile)
            }
        }
    }

    /// Flat tiles, separated by the gaps between them. Bodies are neutral and
    /// only the title band carries the kind's colour; a thin top-left
    /// highlight and soft shadow lift each tile off its parent. One path per
    /// depth and colour keeps it to a handful of draws; depth order matters,
    /// since children paint over their parent's body.
    private func paintFills(_ context: inout GraphicsContext) {
        struct Title: Hashable {
            let kind: Kind
            let levelsBelow: Int
        }
        var outlines: [Int: Path] = [:]
        var bodies: [Int: [Int: Path]] = [:]
        var titles: [Int: [Title: Path]] = [:]
        var striped: [Int: [Tile]] = [:]
        var highlights = Path()
        var shades = Path()
        for tile in tiles {
            // Small items are no tile at all, just a label carved into the
            // parent, so they never pass for a file.
            guard let node = tile.node else {
                continue
            }
            let radius = tileRadius(tile)
            let outline = rounded(tile.rect, radius)
            outlines[tile.depth, default: Path()].addPath(outline)
            bodies[tile.depth, default: [:]][tile.levelsBelow, default: Path()].addPath(outline)
            // A file is all colour, a folder only its band: told apart at a glance.
            titles[tile.depth, default: [:]][
                Title(kind: node.kind, levelsBelow: tile.levelsBelow), default: Path()
            ].addPath(tile.isBlock ? outline : titleShape(tile))
            // A System folder open for its reclaimable space says so in its band.
            if node.kind == .system, tile.header != nil {
                striped[tile.depth, default: []].append(tile)
            }
            // Up the left side and along the top, following the corner.
            let inner = tile.rect.insetBy(dx: 0.5, dy: 0.5)
            highlights.move(to: CGPoint(x: inner.minX, y: inner.maxY - radius))
            highlights.addLine(to: CGPoint(x: inner.minX, y: inner.minY + radius))
            highlights.addQuadCurve(
                to: CGPoint(x: inner.minX + radius, y: inner.minY),
                control: CGPoint(x: inner.minX, y: inner.minY))
            highlights.addLine(to: CGPoint(x: inner.maxX - radius, y: inner.minY))
            // And the bevel's shade, down the right side and along the bottom.
            shades.move(to: CGPoint(x: inner.maxX, y: inner.minY + radius))
            shades.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY - radius))
            shades.addQuadCurve(
                to: CGPoint(x: inner.maxX - radius, y: inner.maxY),
                control: CGPoint(x: inner.maxX, y: inner.maxY))
            shades.addLine(to: CGPoint(x: inner.minX + radius, y: inner.maxY))
        }
        let environment = context.environment
        context.fill(
            Path(CGRect(origin: .zero, size: context.clipBoundingRect.size)),
            with: .color(Palette.well(in: environment)))
        let dark = environment.colorScheme == .dark
        for depth in outlines.keys.sorted() {
            // A soft shadow on the parent, so deep stacks of similar greys
            // still read as layers; clipped to the parent, never spilling.
            var layer = context
            if let parents = outlines[depth - 1] {
                layer.clip(to: parents)
            }
            layer.addFilter(.shadow(color: .black.opacity(dark ? 0.35 : 0.1), radius: 5, y: 1))
            for (levels, path) in bodies[depth] ?? [:] {
                layer.fill(
                    path, with: .color(Palette.body(levelsBelow: levels, in: environment)))
            }
            for (title, path) in titles[depth] ?? [:] {
                context.fill(
                    path,
                    with: .color(Palette.title(
                        title.kind, levelsBelow: title.levelsBelow, in: environment)))
            }
            for tile in striped[depth] ?? [] {
                var band = context
                band.clip(to: titleShape(tile))
                band.fill(
                    stripes(across: tile.title),
                    with: .color(Palette.title(
                        .reclaimable, levelsBelow: tile.levelsBelow, in: environment)))
            }
        }
        context.stroke(highlights, with: .color(.white.opacity(dark ? 0.08 : 0.8)), lineWidth: 1)
        context.stroke(shades, with: .color(.black.opacity(dark ? 0.4 : 0.12)), lineWidth: 1)
    }

    /// A small orange corner: part of it could not be read.
    private func paintUnreadable(_ context: inout GraphicsContext) {
        var marks = Path()
        for tile in tiles {
            if let node = tile.node, node.unreadableHere, tile.rect.width > 12,
                tile.rect.height > 12
            {
                marks.addRect(
                    CGRect(x: tile.rect.maxX - 6, y: tile.rect.minY + 2, width: 4, height: 4))
            }
        }
        context.fill(marks, with: .color(Color(nsColor: .systemOrange)))
    }

    private func paintLabel(_ context: inout GraphicsContext, _ tile: Tile) {
        guard let node = tile.node else {
            paintSmallItemsLabel(&context, tile)
            return
        }
        guard !tile.isBlock else {
            paintFileLabel(&context, tile, node)
            return
        }
        let owned = tile.title
        let text = ([node] + tile.chain).map(\.displayName).joined(separator: " \u{203A} ")
        let size = formatBytes(node.bytes)
        let bold = tile.depth == 0 && tile.header != nil
        let name = context.resolve(
            Text(text).font(.system(size: 12.5, weight: bold ? .semibold : .regular))
                .foregroundStyle(.primary))
        let sizeText = context.resolve(
            Text(size).font(.system(size: 12)).foregroundStyle(.secondary))

        // Clear of the corner's curve.
        let padding: CGFloat = 9
        let lineHeight: CGFloat = 16
        let unbounded = CGSize(width: 10_000, height: 100)
        let nameSize = name.measure(in: unbounded)
        let nameWidth = nameSize.width
        let sizeWidth = sizeText.measure(in: unbounded).width
        let origin = CGPoint(x: owned.minX + padding, y: owned.midY - nameSize.height / 2)
        let sizeBelow = tile.header == nil && tile.rect.maxY - owned.maxY >= lineHeight + 4
        let sizeBeside = !sizeBelow && owned.width - padding * 2 - nameWidth > sizeWidth + 8

        // A leaf may put its size below the band, so it owns the whole tile.
        var label = context
        let area = tile.header ?? tile.rect
        label.clip(to: Path(area))
        if origin.x + nameWidth > area.maxX - 4 {
            fadeOut(&label, area)
        }
        label.draw(name, at: origin, anchor: .topLeading)
        if sizeBelow {
            // A folder too small to open shows what it holds, centred in its
            // body, so it doesn't pass for a whole thing.
            let body = CGRect(
                x: tile.rect.minX, y: owned.maxY, width: tile.rect.width,
                height: tile.rect.maxY - owned.maxY)
            let items = context.resolve(
                Text("\(formatCount(node.children.count)) items \u{00B7} \(size)")
                    .font(.system(size: 12)).foregroundStyle(.secondary))
            let room = body.width - padding * 2
            let center = CGPoint(x: body.midX, y: body.midY)
            if items.measure(in: unbounded).width <= room {
                label.draw(items, at: center, anchor: .center)
            } else if sizeWidth <= room {
                label.draw(sizeText, at: center, anchor: .center)
            }
        } else if sizeBeside {
            label.draw(
                sizeText, at: CGPoint(x: origin.x + nameWidth + 6, y: origin.y),
                anchor: .topLeading)
        }
    }

    /// Centred, with the size below if there is room; a name too long to
    /// centre starts at the left and fades out.
    private func paintFileLabel(_ context: inout GraphicsContext, _ tile: Tile, _ node: Node) {
        let name = context.resolve(
            Text(node.displayName).font(.system(size: 12.5)).foregroundStyle(.primary))
        let size = context.resolve(
            Text(formatBytes(node.bytes)).font(.system(size: 12)).foregroundStyle(.secondary))
        let padding: CGFloat = 9
        let unbounded = CGSize(width: 10_000, height: 100)
        let room = tile.rect.width - padding * 2
        let twoLines = tile.rect.height >= 40
        let lines = twoLines ? [name, size] : [name]
        var label = context
        label.clip(to: Path(tile.rect))
        if lines.contains(where: { $0.measure(in: unbounded).width > room }) {
            fadeOut(&label, tile.rect)
        }
        let heights = lines.map { $0.measure(in: unbounded).height }
        let textHeight = heights.reduce(0, +) + (twoLines ? 2 : 0)
        var y = tile.rect.midY - textHeight / 2
        // A package shows its icon above the name, when there is room for one.
        let icon = min(64, room, tile.rect.height - textHeight - 20)
        if node.isPackage, icon >= 20 {
            let top = tile.rect.midY - (icon + 6 + textHeight) / 2
            context.draw(
                Image(nsImage: packageIcon(node.path)),
                in: CGRect(x: tile.rect.midX - icon / 2, y: top, width: icon, height: icon))
            y = top + icon + 6
        }
        for (line, height) in zip(lines, heights) {
            let width = line.measure(in: unbounded).width
            let x = width > room ? tile.rect.minX + padding : tile.rect.midX - width / 2
            label.draw(line, at: CGPoint(x: x, y: y), anchor: .topLeading)
            y += height + 2
        }
    }

    /// Text too long for its tile fades out 4 pt short of the right edge.
    private func fadeOut(_ label: inout GraphicsContext, _ area: CGRect) {
        let end = area.maxX - 4
        label.clipToLayer { mask in
            mask.fill(
                Path(area),
                with: .linearGradient(
                    Gradient(colors: [.black, .clear]),
                    startPoint: CGPoint(x: end - 15, y: 0), endPoint: CGPoint(x: end, y: 0)))
        }
    }

    /// Centred and italic, with its size below if there is room: carved into
    /// the parent, dark with a light edge below, like letterpress.
    private func paintSmallItemsLabel(_ context: inout GraphicsContext, _ tile: Tile) {
        let dark = context.environment.colorScheme == .dark
        let ink = Color.black.opacity(dark ? 0.9 : 0.4)
        let edge = Color.white.opacity(dark ? 0.22 : 0.9)
        let font = Font.system(size: 12.5).italic()
        // Too narrow for the phrase: an ellipsis still says "more in here".
        guard case .others(_, _, let count) = tile.content else {
            return
        }
        let title = smallItemsTitle(count)
        let measured = context.resolve(Text(title).font(font))
            .measure(in: .init(width: 1000, height: 100))
        guard tile.rect.height >= measured.height else {
            return
        }
        let fits = measured.width <= tile.rect.width - 8
        var lines = [Text(fits ? title : "\u{2026}").font(font)]
        if fits && tile.rect.height >= 40 {
            lines.append(Text(formatBytes(tile.content.bytes)).font(.system(size: 12)))
        }
        var label = context
        label.clip(to: Path(tile.rect))
        let center = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        for (color, offset) in [(edge, 1.0), (ink, 0.0)] {
            if lines.count == 1 {
                label.draw(
                    lines[0].foregroundStyle(color), at: CGPoint(x: center.x, y: center.y + offset),
                    anchor: .center)
            } else {
                label.draw(
                    lines[0].foregroundStyle(color), at: CGPoint(x: center.x, y: center.y + offset),
                    anchor: .bottom)
                label.draw(
                    lines[1].foregroundStyle(color),
                    at: CGPoint(x: center.x, y: center.y + 2 + offset), anchor: .top)
            }
        }
    }
}

private struct RingsCanvas: View {
    let tiles: [Tile]
    let hovered: Tile.Content?
    let selected: Tile.Content?

    var body: some View {
        Canvas { context, _ in
            if let hovered, hovered != selected, let tile = tile(of: hovered) {
                context.stroke(
                    rounded(tile.rect.insetBy(dx: 0.5, dy: 0.5), tileRadius(tile)),
                    with: .color(.primary.opacity(0.4)), lineWidth: 1)
            }
            if let selected, let tile = tile(of: selected) {
                context.stroke(
                    rounded(tile.rect.insetBy(dx: 1, dy: 1), tileRadius(tile) - 1),
                    with: .color(.accentColor), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func tile(of content: Tile.Content) -> Tile? {
        tiles.first { $0.content == content }
    }
}

/// Diagonal bands, as wide as the gaps between them.
private func stripes(across rect: CGRect) -> Path {
    var path = Path()
    let width: CGFloat = 6
    var x = rect.minX - rect.height
    while x < rect.maxX {
        path.move(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        path.addLine(to: CGPoint(x: x + rect.height + width, y: rect.minY))
        path.addLine(to: CGPoint(x: x + width, y: rect.maxY))
        path.closeSubpath()
        x += width * 2
    }
    return path
}


/// Icons are looked up once per package; the mosaic repaints on every resize.
@MainActor private var packageIcons: [String: NSImage] = [:]

@MainActor private func packageIcon(_ path: String) -> NSImage {
    if let icon = packageIcons[path] {
        return icon
    }
    let icon = NSWorkspace.shared.icon(forFile: path)
    // The icon comes sized 32 pt, and draws from its 32 pt image when scaled up.
    icon.size = NSSize(width: 128, height: 128)
    packageIcons[path] = icon
    return icon
}

func smallItemsTitle(_ count: Int) -> String {
    "\(formatCount(count)) small items"
}

/// Close to the window's own corners; top-level tiles a little rounder,
/// so that level reads first.
private func tileRadius(_ tile: Tile) -> CGFloat {
    tile.depth == 0 ? 10 : 8
}

/// Thin small items get their radius capped, so the ends stay round.
private func rounded(_ rect: CGRect, _ radius: CGFloat) -> Path {
    let radius = max(min(radius, rect.width / 2, rect.height / 2), 0)
    return Path(roundedRect: rect, cornerSize: CGSize(width: radius, height: radius))
}

/// The title band shares the tile's top corners; its bottom is square unless
/// it is the whole tile.
private func titleShape(_ tile: Tile) -> Path {
    let radius = tileRadius(tile)
    let bottom = tile.title.maxY >= tile.rect.maxY ? radius : 0
    return UnevenRoundedRectangle(
        topLeadingRadius: radius, bottomLeadingRadius: bottom,
        bottomTrailingRadius: bottom, topTrailingRadius: radius
    ).path(in: tile.title)
}
