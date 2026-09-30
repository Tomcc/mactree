import Foundation

/// "Worth a look": reclaimable directories big enough to matter. Topmost
/// only, so the total is space that really exists once.
public func worthALook(_ root: Node) -> [Node] {
    var found: [Node] = []
    func visit(_ node: Node) {
        guard node.isDir, node.bytes >= minWorthBytes else {
            return
        }
        if node.reclaim != nil {
            found.append(node)
            return
        }
        node.children.forEach(visit)
    }
    root.children.forEach(visit)
    return found
}

/// Smaller than this is not worth a line.
private let minWorthBytes: UInt64 = 64 * 1024 * 1024

/// Decimal units, like Finder: "881 GB", "9.7 GB", "15 MB".
public func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 999.5 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    let digits = unit == 0 || value >= 9.95 ? 0 : 1
    return String(format: "%.\(digits)f ", value) + units[unit]
}

/// "3.9M", "499.4k", "812".
public func formatCount(_ count: Int) -> String {
    switch count {
    case ..<1000: "\(count)"
    case ..<1_000_000: String(format: "%.1fk", Double(count) / 1e3)
    default: String(format: "%.1fM", Double(count) / 1e6)
    }
}

public struct DiskSpace: Sendable {
    public let volumeName: String
    /// What Finder calls available: free plus purgeable.
    public let available: UInt64
    public let total: UInt64

    public init(for path: String) throws {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else {
            throw CocoaError(.fileReadUnknown)
        }
        self.volumeName = values.volumeName ?? path
        self.available = UInt64(available)
        self.total = UInt64(total)
    }
}
