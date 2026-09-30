import Foundation

/// One file or directory of a scan. Directory totals are derived from the
/// children by `recompute()`, never tracked by hand.
public final class Node: @unchecked Sendable {
    /// The last path component; the scanned root holds its full path.
    /// Mutable because the Trash may rename what is moved into it.
    public var name: String
    public let isDir: Bool
    /// Unowned rather than weak: a weak ref costs a side table per node, and
    /// a scan can hold millions. Parents always outlive their children.
    public unowned(unsafe) var parent: Node?
    /// Largest first, once aggregated.
    public var children: [Node] = []
    /// Disk usage (allocated blocks): what comes back when it is deleted.
    public var bytes: UInt64
    /// Files at or below this node; 1 for a file.
    public var files: Int
    /// Directories strictly below this node.
    public var dirs: Int = 0
    /// Newest modification time in the subtree, Unix seconds.
    public var newest: Int
    /// This directory itself could not be listed.
    public var unreadableHere = false
    /// Directories below (and including) this one that could not be listed.
    public var unreadable = 0
    /// A mount point: counted as empty and never entered.
    public var isMountPoint = false
    public var kind: Kind = .other
    public var reclaim: Reclaim?
    /// A file some repository tracks, or a folder of only such files.
    public var tracked = false
    /// Reclaimable itself or somewhere below: a System folder shows its
    /// contents only then, since that is the one reason to look inside.
    public var holdsReclaimable = false

    public init(name: String, isDir: Bool, bytes: UInt64 = 0, newest: Int = 0) {
        self.name = name
        self.isDir = isDir
        self.bytes = bytes
        self.files = isDir ? 0 : 1
        self.newest = newest
    }

    public var path: String {
        guard let parent else {
            return name
        }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// The name to show: the root's full path shortened to its last part.
    public var displayName: String {
        parent == nil ? (name as NSString).lastPathComponent : name
    }

    /// From the root down to this node, inclusive.
    public var ancestry: [Node] {
        var chain: [Node] = []
        var cursor: Node? = self
        while let node = cursor {
            chain.append(node)
            cursor = node.parent
        }
        return chain.reversed()
    }

    public func isDescendant(of other: Node) -> Bool {
        var cursor: Node? = self
        while let node = cursor {
            if node === other {
                return true
            }
            cursor = node.parent
        }
        return false
    }

    public func adopt(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    /// Re-derive this directory's totals from its direct children.
    public func recompute() {
        guard isDir else {
            return
        }
        var bytes: UInt64 = 0
        var files = 0
        var dirs = 0
        var newest = 0
        var unreadable = unreadableHere ? 1 : 0
        for child in children {
            bytes += child.bytes
            files += child.files
            dirs += child.isDir ? child.dirs + 1 : 0
            newest = max(newest, child.newest)
            unreadable += child.unreadable
        }
        self.bytes = bytes
        self.files = files
        self.dirs = dirs
        self.newest = newest
        self.unreadable = unreadable
        children.sort { $0.bytes > $1.bytes }
    }

    /// Bottom-up totals for the whole subtree.
    public func aggregate() {
        for child in children where child.isDir {
            child.aggregate()
        }
        recompute()
    }

    /// Re-derive every ancestor after this node's subtree changed.
    public func propagateUp() {
        var cursor = parent
        while let node = cursor {
            node.recompute()
            cursor = node.parent
        }
    }
}
