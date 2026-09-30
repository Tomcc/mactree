import CoreGraphics

// Squarified treemap (Bruls, Huizing, van Wijk), ported from disktree's
// treemap.rs: grow a row while its worst aspect ratio improves, then start
// the next row in the space left.

public struct Tile: Sendable {
    public enum Content: Sendable {
        case node(Node)
        /// The merged tail of a long child list, so its area still counts.
        case others(parent: Node, count: Int)
    }

    public let content: Content
    public let rect: CGRect
    /// 0 for the children of the drawn directory.
    public let depth: Int
    /// The band a subdivided directory keeps for its own name; its children
    /// are laid out below it, and it hit-tests as the parent.
    public let header: CGRect?

    public var node: Node? {
        if case .node(let node) = content {
            return node
        }
        return nil
    }
}

public struct LayoutOptions: Equatable, Sendable {
    public var padding: CGFloat = 1
    /// Wider gaps between top-level directories, so that level reads first.
    public var paddingOuter: CGFloat = 3
    /// Smaller tiles are dropped: they cannot be read, and they are noise.
    public var minTile: CGFloat = 15
    public var maxChildren = 96
    public var header: CGFloat = 18
    public var headerInner: CGFloat = 15
    /// A directory is subdivided only if the body under its band is at least
    /// this big: depth follows the room on screen, not a fixed level count.
    /// Room for about three by three of the smallest tiles.
    public var minBody = CGSize(width: 45, height: 45)

    public init() {}
}

/// Parents come before their children, so painting in order and hit-testing
/// in reverse both do the right thing.
public func layout(_ root: Node, in area: CGRect, options: LayoutOptions) -> [Tile] {
    var tiles: [Tile] = []
    placeChildren(of: root, in: area, depth: 0, options: options, into: &tiles)
    return tiles
}

private func placeChildren(
    of node: Node, in area: CGRect, depth: Int, options: LayoutOptions,
    into tiles: inout [Tile]
) {
    guard area.width > 0, area.height > 0 else {
        return
    }
    let ranked = node.children.filter { $0.bytes > 0 }
    let kept = ranked.prefix(options.maxChildren)
    var items: [(content: Tile.Content, value: Double)] = kept.map {
        (.node($0), Double($0.bytes))
    }
    let tail = ranked.count - kept.count
    if tail > 0 {
        let bytes = ranked.dropFirst(kept.count).reduce(0) { $0 + Double($1.bytes) }
        items.append((.others(parent: node, count: tail), bytes))
    }
    guard !items.isEmpty else {
        return
    }
    items.sort { $0.value > $1.value }

    let padding = depth == 0 ? options.paddingOuter : options.padding
    for (item, raw) in zip(items, squarify(items.map(\.value), in: area)) {
        let rect = raw.insetBy(dx: padding, dy: padding)
        guard rect.width >= options.minTile, rect.height >= options.minTile else {
            continue
        }
        guard case .node(let child) = item.content, child.isDir else {
            tiles.append(Tile(content: item.content, rect: rect, depth: depth, header: nil))
            continue
        }
        // No room for a band and a readable body: the tile stays whole.
        let header = headerBand(rect, depth: depth, options: options)
        tiles.append(Tile(content: item.content, rect: rect, depth: depth, header: header))
        if let header {
            let body = CGRect(
                x: rect.minX, y: header.maxY, width: rect.width,
                height: rect.maxY - header.maxY)
            placeChildren(
                of: child, in: body, depth: depth + 1, options: options, into: &tiles)
        }
    }
}

private func headerBand(_ rect: CGRect, depth: Int, options: LayoutOptions) -> CGRect? {
    let height = depth == 0 ? options.header : options.headerInner
    guard rect.width >= options.minBody.width,
        rect.height - height >= options.minBody.height
    else {
        return nil
    }
    return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
}

/// One rectangle per value, proportional to it, in the order of `values`.
/// Expects `values` sorted largest first.
public func squarify(_ values: [Double], in area: CGRect) -> [CGRect] {
    var rects = Array(repeating: CGRect.zero, count: values.count)
    let total = values.reduce(0) { $0 + max($1, 0) }
    guard total > 0, area.width > 0, area.height > 0 else {
        return rects
    }
    let scale = Double(area.width * area.height) / total
    let areas = values.map { max($0, 0) * scale }

    var free = area
    var start = 0
    while start < areas.count {
        let side = Double(min(free.width, free.height))
        var end = start + 1
        var rowSum = areas[start]
        var rowWorst = worstRatio(areas[start..<end], sum: rowSum, side: side)
        while end < areas.count {
            let sum = rowSum + areas[end]
            let worst = worstRatio(areas[start...end], sum: sum, side: side)
            if worst > rowWorst {
                break
            }
            rowSum = sum
            rowWorst = worst
            end += 1
        }

        if free.width >= free.height {
            // A strip down the left; tiles stack top to bottom.
            let stripW = min(CGFloat(rowSum / Double(free.height)), free.width)
            var y = free.minY
            for index in start..<end {
                let h = stripW > 0 ? CGFloat(areas[index] / Double(stripW)) : 0
                let height = max(min(h, free.maxY - y), 0)
                rects[index] = CGRect(x: free.minX, y: y, width: stripW, height: height)
                y += height
            }
            free = CGRect(
                x: free.minX + stripW, y: free.minY, width: free.width - stripW,
                height: free.height)
        } else {
            // A strip along the top; tiles run left to right.
            let stripH = min(CGFloat(rowSum / Double(free.width)), free.height)
            var x = free.minX
            for index in start..<end {
                let w = stripH > 0 ? CGFloat(areas[index] / Double(stripH)) : 0
                let width = max(min(w, free.maxX - x), 0)
                rects[index] = CGRect(x: x, y: free.minY, width: width, height: stripH)
                x += width
            }
            free = CGRect(
                x: free.minX, y: free.minY + stripH, width: free.width,
                height: free.height - stripH)
        }
        start = end
    }
    return rects
}

private func worstRatio(_ areas: ArraySlice<Double>, sum: Double, side: Double) -> Double {
    guard sum > 0, side > 0 else {
        return .infinity
    }
    let thickness = sum / side
    return areas.reduce(0) { worst, area in
        guard area > 0 else {
            return worst
        }
        let other = area / thickness
        return max(worst, max(thickness / other, other / thickness))
    }
}

/// The deepest tile under a point.
public func hit(_ tiles: [Tile], at point: CGPoint) -> Tile? {
    tiles.last { $0.rect.contains(point) }
}
