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
                    model.hovered = hit(tiles, at: point)?.node
                case .ended:
                    model.hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                let node = hit(tiles, at: point)?.node
                // Double-click opens; a tap gesture of count 2 would delay
                // every single click while it waits.
                if let node, NSApp.currentEvent?.clickCount == 2 {
                    model.open(node)
                } else {
                    model.selected = node
                }
            }
            .contextMenu {
                if let node = model.hovered {
                    NodeMenu(model: model, node: node)
                }
            }
        }
        .background(Palette.background)
    }
}

struct NodeMenu: View {
    let model: AppModel
    let node: Node

    var body: some View {
        if node.isDir {
            Button("Open") { model.open(node) }
        }
        Button("Show in Finder") { model.revealInFinder(node) }
        Divider()
        Button("Move to Trash") { model.moveToTrash(node) }
            .disabled(!model.canTrash(node))
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
            paintHatch(&context)
            paintUnreadable(&context)
            for tile in tiles {
                paintLabel(&context, tile)
            }
        }
    }

    /// Tiles are raised cards, like macOS bezels: a soft shadow below and a
    /// faint highlight along the top edge separate them, not a drawn line.
    /// One path per depth and kind keeps it to a handful of draws; depth order
    /// matters, since children paint over their parent's body.
    private func paintFills(_ context: inout GraphicsContext) {
        let dark = context.environment.colorScheme == .dark
        var layers: [Int: [Kind: Path]] = [:]
        var highlights = Path()
        for tile in tiles {
            let kind: Kind
            switch tile.content {
            case .node(let node): kind = node.kind
            case .others(let parent, _): kind = parent.kind
            }
            let radius = tileRadius(tile)
            layers[tile.depth, default: [:]][kind, default: Path()]
                .addRoundedRect(in: tile.rect, cornerSize: CGSize(width: radius, height: radius))
            highlights.move(to: CGPoint(x: tile.rect.minX + radius, y: tile.rect.minY + 0.5))
            highlights.addLine(to: CGPoint(x: tile.rect.maxX - radius, y: tile.rect.minY + 0.5))
        }
        var raised = context
        raised.addFilter(
            .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 1.5, x: 0, y: 0.5))
        for depth in layers.keys.sorted() {
            for (kind, path) in layers[depth] ?? [:] {
                let fill = Palette.fill(kind, depth: depth, in: context.environment)
                raised.fill(path, with: .color(fill))
            }
        }
        context.stroke(
            highlights, with: .color(.white.opacity(dark ? 0.09 : 0.7)), lineWidth: 1)
    }

    /// "Smaller items" is many things too small to draw, hatched so it reads
    /// as a crowd rather than one more file.
    private func paintHatch(_ context: inout GraphicsContext) {
        var region = Path()
        for tile in tiles {
            if case .others = tile.content {
                let radius = tileRadius(tile)
                region.addRoundedRect(
                    in: tile.rect, cornerSize: CGSize(width: radius, height: radius))
            }
        }
        guard !region.isEmpty else {
            return
        }
        var hatch = context
        hatch.clip(to: region)
        let bounds = region.boundingRect
        var lines = Path()
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            lines.move(to: CGPoint(x: x, y: bounds.maxY))
            lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 5
        }
        hatch.stroke(lines, with: .color(.primary.opacity(0.12)), lineWidth: 1)
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
        // A subdivided directory's name lives in its band, a leaf's at its top.
        let owned = tile.header ?? tile.rect
        let text: String
        let size: String
        switch tile.content {
        case .node(let node):
            text = node.displayName
            size = formatBytes(node.bytes)
        case .others(_, let count):
            text = "\(count) smaller items"
            size = ""
        }
        let bold = tile.depth == 0 && tile.header != nil
        let name = context.resolve(
            Text(text).font(.system(size: 11, weight: bold ? .semibold : .regular))
                .foregroundStyle(.primary))
        let sizeText = context.resolve(
            Text(size).font(.system(size: 11)).foregroundStyle(.secondary))

        var label = context
        label.clip(to: Path(owned))
        let padding: CGFloat = 5
        let lineHeight: CGFloat = 14
        let origin = CGPoint(
            x: owned.minX + padding, y: owned.minY + (tile.header == nil ? 3 : 1))
        label.draw(name, at: origin, anchor: .topLeading)
        guard !size.isEmpty else {
            return
        }
        let nameWidth = name.measure(in: owned.size).width
        let sizeWidth = sizeText.measure(in: owned.size).width
        if tile.header != nil && tile.depth == 0 {
            // First-level sizes sit at the far end, where they read as a column.
            let x = owned.maxX - padding - sizeWidth
            if x > origin.x + nameWidth + padding {
                label.draw(sizeText, at: CGPoint(x: x, y: origin.y), anchor: .topLeading)
            }
        } else if tile.header == nil && owned.height >= lineHeight * 2 + 4 {
            label.draw(
                sizeText, at: CGPoint(x: origin.x, y: origin.y + lineHeight),
                anchor: .topLeading)
        } else if owned.width - padding * 2 - nameWidth > sizeWidth + 8 {
            label.draw(
                sizeText, at: CGPoint(x: origin.x + nameWidth + 6, y: origin.y),
                anchor: .topLeading)
        }
    }
}

private struct RingsCanvas: View {
    let tiles: [Tile]
    let hovered: Node?
    let selected: Node?

    var body: some View {
        Canvas { context, _ in
            if let hovered, hovered !== selected, let tile = tile(of: hovered) {
                context.stroke(
                    ring(tile, inset: 0.5), with: .color(.primary.opacity(0.4)), lineWidth: 1)
            }
            if let selected, let tile = tile(of: selected) {
                context.stroke(ring(tile, inset: 1), with: .color(.accentColor), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func tile(of node: Node) -> Tile? {
        tiles.first { $0.node === node }
    }

    private func ring(_ tile: Tile, inset: CGFloat) -> Path {
        let radius = max(tileRadius(tile) - inset, 0)
        return Path(
            roundedRect: tile.rect.insetBy(dx: inset, dy: inset),
            cornerSize: CGSize(width: radius, height: radius))
    }
}

/// Top-level cards are rounder, so that level reads first.
private func tileRadius(_ tile: Tile) -> CGFloat {
    tile.depth == 0 ? 5 : 3
}
