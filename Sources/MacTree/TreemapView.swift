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
                guard let node = hit(tiles, at: point)?.node else {
                    return
                }
                // Double-click opens; a tap gesture of count 2 would delay
                // every single click while it waits.
                if NSApp.currentEvent?.clickCount == 2 {
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
        .background(Theme.inset.color)
    }
}

struct NodeMenu: View {
    let model: AppModel
    let node: Node

    var body: some View {
        Text(node.displayName)
        if node.isDir {
            Button("Open") { model.open(node) }
        }
        Button("Reveal in Finder") { model.revealInFinder(node) }
        Divider()
        Button("Move to Trash…") { model.pendingTrash = node }
            .disabled(model.trashRefusal(node) != nil)
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
            paintMarks(&context)
            for tile in tiles {
                paintLabel(&context, tile)
            }
        }
    }

    /// One path per depth and colour: a handful of fills instead of thousands.
    /// Depth order matters, since children paint over their parent's body.
    private func paintFills(_ context: inout GraphicsContext) {
        var layers: [Int: [RGB: Path]] = [:]
        var strips: [RGB: Path] = [:]
        for tile in tiles {
            let kind: Kind =
                switch tile.content {
                case .node(let node): node.kind
                case .others(let parent, _): parent.kind
                }
            let fill = Palette.fill(kind, depth: tile.depth)
            layers[tile.depth, default: [:]][fill, default: Path()].addRect(tile.rect)
            // A top-level directory carries a strip of its colour, so the
            // first level of structure reads before any detail.
            if tile.depth == 0, tile.node != nil {
                let strip = CGRect(
                    x: tile.rect.minX, y: tile.rect.minY, width: tile.rect.width,
                    height: min(2, tile.rect.height))
                strips[Palette.accent(kind), default: Path()].addRect(strip)
            }
        }
        for depth in layers.keys.sorted() {
            for (color, path) in layers[depth] ?? [:] {
                context.fill(path, with: .color(color.color))
            }
        }
        for (color, path) in strips {
            context.fill(path, with: .color(color.color))
        }
    }

    /// Reclaimable space is hatched over any hue. Everything inside a
    /// reclaimable directory is too, so one clipped pass covers it all.
    private func paintHatch(_ context: inout GraphicsContext) {
        var region = Path()
        for tile in tiles where tile.node?.reclaim != nil {
            region.addRect(tile.rect)
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
            x += 6
        }
        hatch.stroke(lines, with: .color(Palette.hatch), lineWidth: 1)
    }

    /// A small amber corner: part of this could not be read.
    private func paintMarks(_ context: inout GraphicsContext) {
        var marks = Path()
        for tile in tiles where tile.rect.width > 12 && tile.rect.height > 12 {
            if let node = tile.node, node.unreadableHere {
                marks.addRect(
                    CGRect(x: tile.rect.maxX - 6, y: tile.rect.minY + 2, width: 4, height: 4))
            }
        }
        context.fill(marks, with: .color(Theme.warning.color))
    }

    private func paintLabel(_ context: inout GraphicsContext, _ tile: Tile) {
        // A subdivided directory's name lives in its band, a leaf's at its top.
        let owned = tile.header ?? tile.rect
        guard owned.width >= 36, owned.height >= 12 else {
            return
        }
        let text: String
        let size: String
        switch tile.content {
        case .node(let node):
            text = node.displayName
            size = formatBytes(node.bytes)
        case .others(_, let count):
            text = "\(count) more"
            size = ""
        }
        let bold = tile.depth == 0 && tile.header != nil
        let name = context.resolve(
            Text(text).font(.system(size: 12, weight: bold ? .semibold : .regular))
                .foregroundStyle(Theme.bright.color.opacity(tile.depth == 0 ? 1 : 0.88)))
        let sizeText = context.resolve(
            Text(size).font(.system(size: 11))
                .foregroundStyle(Theme.bright.color.opacity(0.45)))

        var label = context
        label.clip(to: Path(owned))
        let padding: CGFloat = 5
        let lineHeight: CGFloat = 16
        let origin = CGPoint(
            x: owned.minX + padding, y: owned.minY + (tile.header == nil ? 3 : 1))
        label.draw(name, at: origin, anchor: .topLeading)
        guard !size.isEmpty else {
            return
        }
        let nameWidth = name.measure(in: owned.size).width
        let sizeWidth = sizeText.measure(in: owned.size).width
        let sizeTop = origin.y + 1
        if tile.header != nil && tile.depth == 0 {
            // First-level sizes sit at the far end, where they read as a column.
            let x = owned.maxX - padding - sizeWidth
            if x > origin.x + nameWidth + padding {
                label.draw(sizeText, at: CGPoint(x: x, y: sizeTop), anchor: .topLeading)
            }
        } else if tile.header == nil && owned.height >= lineHeight * 2 + 4 {
            label.draw(
                sizeText, at: CGPoint(x: origin.x, y: origin.y + lineHeight),
                anchor: .topLeading)
        } else if owned.width - padding * 2 - nameWidth > sizeWidth + 8 {
            label.draw(
                sizeText, at: CGPoint(x: origin.x + nameWidth + 7, y: sizeTop),
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
                    Path(tile.rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Palette.hover),
                    lineWidth: 1)
            }
            if let selected, let tile = tile(of: selected) {
                context.stroke(
                    Path(tile.rect.insetBy(dx: 1, dy: 1)), with: .color(Theme.warning.color),
                    lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func tile(of node: Node) -> Tile? {
        tiles.first { $0.node === node }
    }
}
