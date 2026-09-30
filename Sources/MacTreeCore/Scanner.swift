import Darwin
import Foundation
import Synchronization

/// Entries seen so far, readable from any thread while a scan runs.
public final class ScanProgress: Sendable {
    let entries = Atomic<Int>(0)

    public init() {}

    public var count: Int { entries.load(ordering: .relaxed) }
}

/// Walks a directory tree with `getattrlistbulk`, which returns names, types
/// and sizes for a whole directory per syscall instead of a `stat` per entry.
public enum Scanner {
    public struct Result: Sendable {
        public let root: Node
        /// Repositories git could not list; their files show as untracked.
        public let gitFailures: [String]
    }

    /// Scan everything under `path` on its volume: aggregated, sorted and
    /// classified. Blocks the calling thread; the walk itself is parallel.
    public static func scan(_ path: String, progress: ScanProgress) -> Result {
        let root = Node(name: path, isDir: true)
        walk(root, path: path, progress: progress)
        root.aggregate()
        let gitFailures = markTracked(root)
        classify(root)
        return Result(root: root, gitFailures: gitFailures)
    }

    /// Fill `dir`'s subtree from disk, without aggregating it.
    static func walk(_ dir: Node, path: String, progress: ScanProgress) {
        let queue = WorkQueue(first: Pending(node: dir, path: path))
        let links = SeenInodes()
        let workers = ProcessInfo.processInfo.activeProcessorCount
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            while let next = queue.next() {
                let subdirs = list(next, buffer: buffer, links: links, progress: progress)
                queue.finish(adding: subdirs)
            }
        }
    }

    private static let bufferSize = 256 * 1024

    /// List one directory into its node; returns the subdirectories to walk.
    private static func list(
        _ pending: Pending,
        buffer: UnsafeMutableRawPointer,
        links: SeenInodes,
        progress: ScanProgress
    ) -> [Pending] {
        let dir = pending.node
        let fd = open(pending.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            dir.unreadableHere = true
            return []
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.returned | Attr.error | Attr.name | Attr.objType
            | Attr.modTime | Attr.fileID
        request.dirattr = Attr.mountStatus
        request.fileattr = Attr.linkCount | Attr.allocSize

        var subdirs: [Pending] = []
        let base = pending.path.hasSuffix("/") ? pending.path : pending.path + "/"
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                dir.unreadableHere = true
                break
            }
            if count == 0 {
                break
            }
            progress.entries.add(Int(count), ordering: .relaxed)
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                if let parsed = Entry(entry), parsed.error == 0 {
                    let node = parsed.node(links: links)
                    dir.adopt(node)
                    if node.isDir && !node.isMountPoint {
                        subdirs.append(Pending(node: node, path: base + node.name))
                    }
                } else {
                    dir.unreadableHere = true
                }
                entry += length
            }
        }
        return subdirs
    }
}

/// Inodes with more than one name, so each is counted once.
private final class SeenInodes: Sendable {
    private let seen = Mutex<Set<UInt64>>([])

    /// True the first time an inode is seen.
    func insert(_ inode: UInt64) -> Bool {
        seen.withLock { $0.insert(inode).inserted }
    }
}

struct Pending: Sendable {
    let node: Node
    let path: String
}

/// Bits of `sys/attr.h`, typed as `attrgroup_t`; several do not import.
private enum Attr {
    static let name: attrgroup_t = 0x0000_0001
    static let objType: attrgroup_t = 0x0000_0008
    static let modTime: attrgroup_t = 0x0000_0400
    static let fileID: attrgroup_t = 0x0200_0000
    static let error: attrgroup_t = 0x2000_0000
    static let returned: attrgroup_t = 0x8000_0000
    static let mountStatus: attrgroup_t = 0x0000_0008
    static let linkCount: attrgroup_t = 0x0000_0001
    static let allocSize: attrgroup_t = 0x0000_0004
    static let mountPointFlag: UInt32 = 0x0000_0001
    static let vdir: UInt32 = 2
}

/// One packed record of a `getattrlistbulk` buffer. Attributes appear in
/// bit order, only when returned, except that the error comes first.
private struct Entry {
    var error: UInt32 = 0
    var name = ""
    var isDir = false
    var modTime = 0
    var fileID: UInt64 = 0
    var isMountPoint = false
    var linkCount: UInt32 = 1
    var allocSize: UInt64 = 0

    init?(_ start: UnsafeMutableRawPointer) {
        var cursor = UnsafeRawPointer(start) + 4
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        if returned.commonattr & Attr.error != 0 {
            error = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        guard returned.commonattr & Attr.name != 0 else {
            return nil
        }
        let reference = cursor.loadUnaligned(as: attrreference_t.self)
        name = String(cString: (cursor + Int(reference.attr_dataoffset))
            .assumingMemoryBound(to: CChar.self))
        cursor += MemoryLayout<attrreference_t>.size
        if returned.commonattr & Attr.objType != 0 {
            isDir = cursor.loadUnaligned(as: UInt32.self) == Attr.vdir
            cursor += 4
        }
        if returned.commonattr & Attr.modTime != 0 {
            modTime = cursor.loadUnaligned(as: timespec.self).tv_sec
            cursor += MemoryLayout<timespec>.size
        }
        if returned.commonattr & Attr.fileID != 0 {
            fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }
        if returned.dirattr & Attr.mountStatus != 0 {
            let status = cursor.loadUnaligned(as: UInt32.self)
            isMountPoint = status & Attr.mountPointFlag != 0
            cursor += 4
        }
        if returned.fileattr & Attr.linkCount != 0 {
            linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if returned.fileattr & Attr.allocSize != 0 {
            allocSize = UInt64(cursor.loadUnaligned(as: off_t.self))
        }
    }

    /// The node for this entry. A hardlinked inode is counted once: later
    /// names for it weigh nothing.
    func node(links: SeenInodes) -> Node {
        if isDir {
            let node = Node(name: name, isDir: true, newest: modTime)
            node.isMountPoint = isMountPoint
            return node
        }
        let counted = linkCount <= 1 || links.insert(fileID)
        return Node(name: name, isDir: false, bytes: counted ? allocSize : 0, newest: modTime)
    }
}

/// A shared stack of directories to list. The walk is done when the stack is
/// empty and no worker is still listing (and so might add more).
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [Pending]
    private var outstanding = 1

    init(first: Pending) {
        stack = [first]
    }

    func next() -> Pending? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && outstanding > 0 {
            condition.wait()
        }
        return stack.popLast()
    }

    func finish(adding more: [Pending]) {
        condition.lock()
        stack.append(contentsOf: more)
        outstanding += more.count - 1
        condition.unlock()
        condition.broadcast()
    }
}
