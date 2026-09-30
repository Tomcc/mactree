import CoreGraphics

// Squarified treemap (Bruls, Huizing, van Wijk), ported from disktree's
// treemap.rs: grow a row while its worst aspect ratio improves, then start
// the next row in the space left.

public struct Tile: Sendable {
    public enum Content: Sendable {
        case node(Node)
        /// The merged tail of a long child list, so its area still counts.
        case others(parent: Node, bytes: UInt64)
    }

    public let content: Content
    public let rect: CGRect
    /// 0 for the children of the drawn directory.
    public let depth: Int
    /// The band a subdivided directory keeps for its own name; its children
    /// are laid out below it, and it hit-tests as the parent.
    public let header: CGRect?
    /// Where the name goes: the header, or the same-height top of a tile
    /// that is not subdivided.
    public let title: CGRect

    init(content: Content, rect: CGRect, depth: Int, header: CGRect?, options: LayoutOptions) {
        self.content = content
        self.rect = rect
        self.depth = depth
        self.header = header
        let height = min(depth == 0 ? options.header : options.headerInner, rect.height)
        title = header ?? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
    }

    public var node: Node? {
        content.node
    }
}

/// Equal when it is the same tile across layouts: nodes compare by identity.
extension Tile.Content: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.node(let a), .node(let b)): a === b
        case (.others(let a, _), .others(let b, _)): a === b
        default: false
        }
    }

    public var node: Node? {
        if case .node(let node) = self {
            return node
        }
        return nil
    }

    /// The node itself, or the folder whose small items these are.
    public var owner: Node {
        switch self {
        case .node(let node): node
        case .others(let parent, _): parent
        }
    }

    public var bytes: UInt64 {
        switch self {
        case .node(let node): node.bytes
        case .others(_, let bytes): bytes
        }
    }
}

public struct LayoutOptions: Equatable, Sendable {
    /// The gap between siblings, which is what separates them.
    public var padding: CGFloat = 3
    /// Top-level tiles sit closer: nesting gaps show depth, and there is none yet.
    public var rootPadding: CGFloat = 1.5
    /// Every tile fits a label; children that would be smaller are merged.
    public var minTile: CGFloat = 30
    public var maxChildren = 96
    /// Title bands, tall enough to leave the name some air.
    public var header: CGFloat = 24
    public var headerInner: CGFloat = 21
    /// A directory is subdivided only if the body under its band has room
    /// for about three by three of the smallest tiles: depth follows the room
    /// on screen, not a fixed level count.
    public var minBody = CGSize(width: 90, height: 90)

    public init() {}
}

/// Parents come before their children, so painting in order and hit-testing
/// in reverse both do the right thing.
public func layout(_ root: Node, in area: CGRect, options: LayoutOptions) -> [Tile] {
    var tiles: [Tile] = []
    placeChildren(of: root, in: area, depth: 0, options: options, into: &tiles)
    return tiles
}

private typealias Placed = (content: Tile.Content, rect: CGRect)

private func placeChildren(
    of node: Node, in area: CGRect, depth: Int, options: LayoutOptions,
    into tiles: inout [Tile]
) {
    for (content, rect) in fitChildren(of: node, in: area, depth: depth, options: options) {
        // No room for a band and a readable body: the tile stays whole.
        guard case .node(let child) = content, child.isDir,
            let header = headerBand(rect, depth: depth, options: options)
        else {
            tiles.append(Tile(
                content: content, rect: rect, depth: depth, header: nil, options: options))
            continue
        }
        let body = CGRect(
            x: rect.minX, y: header.maxY, width: rect.width, height: rect.maxY - header.maxY)
        // A body holding nothing but small items says less than the whole tile.
        let inner = fitChildren(of: child, in: body, depth: depth + 1, options: options)
        if inner.count == 1, case .others = inner[0].content {
            tiles.append(Tile(
                content: content, rect: rect, depth: depth, header: nil, options: options))
            continue
        }
        tiles.append(Tile(
            content: content, rect: rect, depth: depth, header: header, options: options))
        placeChildren(of: child, in: body, depth: depth + 1, options: options, into: &tiles)
    }
}

/// Children big enough for a tile of their own, largest first, and one
/// "small items" tile for the rest, so a big child beside a lot of dust still
/// reads as both. Area alone can still yield a thin strip, so while any child
/// is too thin for a label, the smallest one joins the small items. Small
/// items may stay thin: they need no label, and demoting for them cascades.
private func fitChildren(
    of node: Node, in area: CGRect, depth: Int, options: LayoutOptions
) -> [Placed] {
    guard area.width > 0, area.height > 0 else {
        return []
    }
    let ranked = node.children.filter { $0.bytes > 0 }
    let total = ranked.reduce(0) { $0 + Double($1.bytes) }
    let bytesToArea = Double(area.width * area.height) / max(total, 1)
    let minArea = Double(options.minTile * options.minTile) * 2
    var kept = ranked.prefix { Double($0.bytes) * bytesToArea >= minArea }.count
    kept = min(kept, options.maxChildren)
    while true {
        var items: [(content: Tile.Content, value: Double)] = ranked.prefix(kept).map {
            (.node($0), Double($0.bytes))
        }
        if kept < ranked.count {
            let bytes = ranked.dropFirst(kept).reduce(0) { $0 + $1.bytes }
            items.append((.others(parent: node, bytes: bytes), Double(bytes)))
        }
        items.sort { $0.value > $1.value }
        let placed = zip(items, squarify(items.map(\.value), in: area)).map { item, raw in
            let padding = depth == 0 ? options.rootPadding : options.padding
            var rect = raw.insetBy(dx: padding, dy: padding)
            // Nested tiles run flush to their folder's right edge, so nesting
            // reads as an indent from the left only.
            if depth > 0, raw.maxX >= area.maxX - 0.5 {
                rect.size.width += padding
            }
            return (item.content, rect)
        }
        let thin = placed.contains { content, rect in
            content.node != nil && (rect.width < options.minTile || rect.height < options.minTile)
        }
        if kept == 0 || !thin {
            return placed.filter { $0.1.width > 0 && $0.1.height > 0 }
        }
        kept -= 1
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
