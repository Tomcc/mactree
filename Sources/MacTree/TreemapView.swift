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
                MosaicCanvas(tiles: tiles, worth: model.worth, version: model.treeVersion)
                    .equatable()
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
    nonisolated let worth: Set<ObjectIdentifier>
    /// Tiles hold references, so equality needs the tree's version too.
    nonisolated let version: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.tiles.count == rhs.tiles.count
            && zip(lhs.tiles, rhs.tiles).allSatisfy { $0.rect == $1.rect }
    }

    var body: some View {
        Canvas { context, _ in
            paintFills(&context)
            paintFree(&context)
            paintOutlines(&context)
            for tile in tiles {
                paintLabel(&context, tile)
            }
        }
    }

    /// One path per depth and kind: a handful of fills instead of thousands.
    /// Depth order matters, since children paint over their parent's body.
    private func paintFills(_ context: inout GraphicsContext) {
        var layers: [Int: [Kind: Path]] = [:]
        for tile in tiles {
            let kind: Kind
            switch tile.content {
            case .node(let node): kind = node.kind
            case .others(let parent, _): kind = parent.kind
            case .free: continue
            }
            layers[tile.depth, default: [:]][kind, default: Path()].addRect(tile.rect)
        }
        for depth in layers.keys.sorted() {
            for (kind, path) in layers[depth] ?? [:] {
                let fill = Palette.fill(kind, depth: depth, in: context.environment)
                context.fill(path, with: .color(fill))
            }
        }
    }

    /// Free space is an empty tile, outlined like a drop target.
    private func paintFree(_ context: inout GraphicsContext) {
        for tile in tiles {
            if case .free = tile.content {
                context.stroke(
                    Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 4),
                    with: .color(.secondary),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// Green: space that can be had back. A small orange corner: part of it
    /// could not be read.
    private func paintOutlines(_ context: inout GraphicsContext) {
        var worthPath = Path()
        var unreadable = Path()
        for tile in tiles {
            guard let node = tile.node else {
                continue
            }
            if worth.contains(ObjectIdentifier(node)) {
                worthPath.addRect(tile.rect.insetBy(dx: 1, dy: 1))
            }
            if node.unreadableHere, tile.rect.width > 12, tile.rect.height > 12 {
                unreadable.addRect(
                    CGRect(x: tile.rect.maxX - 6, y: tile.rect.minY + 2, width: 4, height: 4))
            }
        }
        context.stroke(worthPath, with: .color(Palette.worth), lineWidth: 2)
        context.fill(unreadable, with: .color(Color(nsColor: .systemOrange)))
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
        case .free(let bytes):
            text = "Free space"
            size = formatBytes(bytes)
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
                    Path(tile.rect.insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(.primary.opacity(0.5)), lineWidth: 1)
            }
            if let selected, let tile = tile(of: selected) {
                context.stroke(
                    Path(tile.rect.insetBy(dx: 1, dy: 1)), with: .color(.accentColor),
                    lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func tile(of node: Node) -> Tile? {
        tiles.first { $0.node === node }
    }
}
