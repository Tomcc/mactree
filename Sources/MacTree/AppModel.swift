import AppKit
import MacTreeCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase {
        case idle
        case scanning(path: String)
        case ready
    }

    private(set) var phase: Phase = .idle
    /// Polled from the scan's atomic counter while scanning.
    private(set) var scannedEntries = 0
    private(set) var root: Node?
    /// Above the scanned folder, from its disk down; going there rescans.
    private(set) var enclosing: [Folder] = []
    /// The directory the mosaic draws.
    private(set) var current: Node?
    /// Tile contents rather than nodes, so small items can be pointed at too.
    var selected: Tile.Content?
    var hovered: Tile.Content?
    private(set) var disk: DiskSpace?
    /// Bumped whenever the tree changes shape, to invalidate the layout.
    private(set) var treeVersion = 0
    private(set) var emptyingTrash = false
    var confirmingEmptyTrash = false
    /// Show inside System folders; off, they are single tiles.
    var revealSystem = false {
        didSet {
            leaveHiddenFolders()
        }
    }
    var showingComputer = false
    var error: String?

    @ObservationIgnored private var layoutCache: (key: LayoutKey, tiles: [Tile])?

    private struct LayoutKey: Equatable {
        let size: CGSize
        let node: ObjectIdentifier
        let version: Int
        let revealSystem: Bool
    }

    /// `showing` is where to land; by default a rescan stays where it was.
    func scan(_ path: String, showing: String? = nil) {
        let progress = ScanProgress()
        phase = .scanning(path: path)
        scannedEntries = 0
        Task {
            let poll = Task {
                while !Task.isCancelled {
                    scannedEntries = progress.count
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let result = await Task.detached { Scanner.scan(path, progress: progress) }.value
            poll.cancel()
            finishScan(result, showing: showing)
        }
    }

    /// Synchronous, for the snapshot tool: blocking is fine in a CLI.
    func scanBlocking(_ path: String) {
        finishScan(Scanner.scan(path, progress: ScanProgress()), showing: nil)
    }

    private func finishScan(_ result: MacTreeCore.Scanner.Result, showing: String?) {
        let tree = result.root
        if let first = result.gitFailures.first {
            error = "Git couldn\u{2019}t list \(result.gitFailures.count) repositories, so their "
                + "files aren\u{2019}t marked Git. The first: \(first)"
        }
        // Keep the user where they were when rescanning the same root.
        let wasAt = showing ?? current?.path
        root = tree
        enclosing = enclosingFolders(of: tree.path)
        current = wasAt.flatMap { find($0, in: tree) } ?? tree
        selected = nil
        hovered = nil
        phase = .ready
        treeChanged()
    }

    /// Free space changes behind our back (Finder, other apps, APFS reclaiming
    /// purgeable space late), and reading it is one cheap call.
    func watchFreeSpace() async {
        while !Task.isCancelled {
            if let root, let fresh = try? DiskSpace(for: root.path),
                fresh.available != disk?.available
            {
                disk = fresh
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func rescan() {
        if let root {
            scan(root.path)
        }
    }

    private func treeChanged() {
        treeVersion += 1
        if let root {
            disk = try? DiskSpace(for: root.path)
        }
    }

    func tiles(for size: CGSize) -> [Tile] {
        guard let current else {
            return []
        }
        let key = LayoutKey(
            size: size, node: ObjectIdentifier(current), version: treeVersion,
            revealSystem: revealSystem)
        if let cache = layoutCache, cache.key == key {
            return cache.tiles
        }
        var options = LayoutOptions()
        options.revealSystem = revealSystem
        let tiles = layout(current, in: CGRect(origin: .zero, size: size), options: options)
        layoutCache = (key, tiles)
        return tiles
    }

    func canOpen(_ node: Node) -> Bool {
        node.isDir && !node.children.isEmpty
            && !node.hidesContents(revealingSystem: revealSystem)
    }

    func open(_ node: Node) {
        guard canOpen(node) else {
            return
        }
        current = node
        selected = nil
        hovered = nil
    }

    /// Hiding System folders again while inside one steps out of it.
    private func leaveHiddenFolders() {
        guard let current,
            let outermost = current.ancestry.first(where: {
                $0.hidesContents(revealingSystem: revealSystem)
            })
        else {
            return
        }
        self.current = outermost.parent ?? root
        selected = .node(outermost)
        hovered = nil
    }

    var canGoUp: Bool {
        current?.parent != nil || !enclosing.isEmpty
    }

    /// Past the scanned folder, this rescans its parent.
    func up() {
        guard let current else {
            return
        }
        guard let parent = current.parent else {
            if let outer = enclosing.last {
                scan(outer.path, showing: outer.path)
            }
            return
        }
        selected = .node(current)
        self.current = parent
    }

    func revealInFinder(_ node: Node) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func canTrash(_ node: Node) -> Bool {
        node !== root && node.path != NSHomeDirectory() && !node.isMountPoint
    }

    /// Recoverable, so no confirmation, like Finder.
    func moveToTrash(_ node: Node) {
        guard canTrash(node), let parent = node.parent else {
            return
        }
        let trashed: NSURL?
        do {
            var result: NSURL?
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: node.path), resultingItemURL: &result)
            trashed = result
        } catch {
            self.error = "Could not move \u{201C}\(node.displayName)\u{201D} to the Trash: "
                + error.localizedDescription
            return
        }
        if let current, current.isDescendant(of: node) {
            self.current = parent
        }
        // The parent's small items change too, so only other folders keep theirs.
        if let owner = selected?.owner, owner.isDescendant(of: node) || owner === parent {
            selected = nil
        }
        hovered = nil
        parent.children.removeAll { $0 === node }
        parent.recompute()
        parent.propagateUp()
        // Same volume: the bytes are still used, now by the Trash.
        if let trash = trashNode, let name = trashed?.lastPathComponent {
            node.name = name
            trash.adopt(node)
            trash.recompute()
            trash.propagateUp()
        }
        treeChanged()
    }

    /// `~/.Trash` in the scanned tree, if the scan reached it.
    var trashNode: Node? {
        root.flatMap { find(trashPath, in: $0) }.flatMap { $0.path == trashPath ? $0 : nil }
    }

    private var trashPath: String { NSHomeDirectory() + "/.Trash" }

    /// Through Finder, which knows every volume's Trash and needs no Full
    /// Disk Access; the first time, macOS asks to let MacTree control Finder.
    func emptyTrash() {
        emptyingTrash = true
        Task {
            let result = await Task.detached { () -> (Int32, String) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
                let errors = Pipe()
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    return (-1, error.localizedDescription)
                }
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: message, as: UTF8.self))
            }.value
            emptyingTrash = false
            guard result.0 == 0 else {
                error = "Could not empty the Trash: \(result.1)"
                return
            }
            if let trash = trashNode {
                trash.children.removeAll()
                trash.recompute()
                trash.propagateUp()
            }
            treeChanged()
        }
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
