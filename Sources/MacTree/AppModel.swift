import AppKit
import MacTreeCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase {
        case idle
        case scanning(path: String, started: Date)
        case ready
    }

    private(set) var phase: Phase = .idle
    /// Polled from the scan's atomic counter while scanning.
    private(set) var scannedEntries = 0
    private(set) var root: Node?
    /// The directory the mosaic draws.
    private(set) var current: Node?
    var selected: Node?
    var hovered: Node?
    private(set) var depth = 4
    private(set) var disk: DiskSpace?
    private(set) var worth: [Node] = []
    private(set) var lastScan: (entries: Int, seconds: Double)?
    /// Bumped whenever the tree changes shape, to invalidate the layout.
    private(set) var treeVersion = 0
    var pendingTrash: Node?
    var error: String?

    @ObservationIgnored private var layoutCache: (key: LayoutKey, tiles: [Tile])?

    private struct LayoutKey: Equatable {
        let size: CGSize
        let node: ObjectIdentifier
        let depth: Int
        let version: Int
    }

    func scan(_ path: String) {
        let progress = ScanProgress()
        let started = Date()
        phase = .scanning(path: path, started: started)
        scannedEntries = 0
        Task {
            let poll = Task {
                while !Task.isCancelled {
                    scannedEntries = progress.count
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let tree = await Task.detached { Scanner.scan(path, progress: progress) }.value
            poll.cancel()
            finishScan(tree, entries: progress.count, seconds: Date().timeIntervalSince(started))
        }
    }

    /// Synchronous, for the snapshot tool: blocking is fine in a CLI.
    func scanBlocking(_ path: String) {
        let progress = ScanProgress()
        let started = Date()
        let tree = Scanner.scan(path, progress: progress)
        finishScan(tree, entries: progress.count, seconds: Date().timeIntervalSince(started))
    }

    private func finishScan(_ tree: Node, entries: Int, seconds: Double) {
        // Keep the user where they were when rescanning the same root.
        let wasAt = current?.path
        root = tree
        current = wasAt.flatMap { find($0, in: tree) } ?? tree
        selected = current
        hovered = nil
        lastScan = (entries, seconds)
        phase = .ready
        treeChanged()
    }

    func rescan() {
        if let root {
            scan(root.path)
        }
    }

    private func treeChanged() {
        treeVersion += 1
        if let root {
            worth = worthALook(root, limit: 6)
            disk = try? DiskSpace(for: root.path)
        }
    }

    func tiles(for size: CGSize) -> [Tile] {
        guard let current else {
            return []
        }
        let key = LayoutKey(
            size: size, node: ObjectIdentifier(current), depth: depth, version: treeVersion)
        if let cache = layoutCache, cache.key == key {
            return cache.tiles
        }
        var options = LayoutOptions()
        options.maxDepth = depth
        let tiles = layout(current, in: CGRect(origin: .zero, size: size), options: options)
        layoutCache = (key, tiles)
        return tiles
    }

    func open(_ node: Node) {
        guard node.isDir, !node.children.isEmpty else {
            return
        }
        current = node
        selected = node
        hovered = nil
    }

    func up() {
        guard let parent = current?.parent else {
            return
        }
        let from = current
        current = parent
        selected = from
    }

    func changeDepth(by delta: Int) {
        depth = min(max(depth + delta, 1), 8)
    }

    func revealInFinder(_ node: Node) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    /// Why a node may not be trashed, if it may not.
    func trashRefusal(_ node: Node) -> String? {
        if node === root {
            return "the scanned folder itself"
        }
        if node.path == NSHomeDirectory() {
            return "your home folder"
        }
        if node.isMountPoint {
            return "a mount point"
        }
        return nil
    }

    func trash(_ node: Node) {
        pendingTrash = nil
        guard trashRefusal(node) == nil, let parent = node.parent else {
            return
        }
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
        } catch {
            self.error = "Could not move \(node.displayName) to the Trash: "
                + error.localizedDescription
            return
        }
        if let current, current.isDescendant(of: node) {
            self.current = parent
        }
        if selected?.isDescendant(of: node) == true {
            selected = parent
        }
        hovered = nil
        parent.children.removeAll { $0 === node }
        parent.recompute()
        parent.propagateUp()
        treeChanged()
    }

    /// Walks our own tree by name, so no path string is parsed from outside.
    private func find(_ path: String, in tree: Node) -> Node? {
        guard path.hasPrefix(tree.path) else {
            return nil
        }
        var node = tree
        for part in path.dropFirst(tree.path.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else {
                return node
            }
            node = next
        }
        return node
    }
}
