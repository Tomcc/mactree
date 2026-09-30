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
    /// Where you were, newest last; paths, so they outlive a rescan.
    private(set) var history: [String] = []
    /// Blocks opened in place with a double-click, until closed again.
    private(set) var unpacked: Set<ObjectIdentifier> = []
    var showingComputer = false
    /// The disk's free space drawn beside its contents, when a disk is scanned.
    var showsFreeSpace = false
    /// Whether the scan is of a whole disk, where free space makes sense.
    private(set) var scannedDisk = false
    var error: String?

    @ObservationIgnored private var layoutCache: (key: LayoutKey, tiles: [Tile])?

    private struct LayoutKey: Equatable {
        let size: CGSize
        let node: ObjectIdentifier
        let version: Int
        let unpacked: Set<ObjectIdentifier>
        let free: FreeSpace?
    }

    /// Background, not a tile: nothing to click, just where the free space would go.
    struct FreeSpace: Equatable {
        let rect: CGRect
        let bytes: UInt64
    }

    /// `showing` is where to land; by default a rescan stays where it was.
    func scan(_ path: String, showing: String? = nil, remembering: Bool = true) {
        if remembering {
            remember()
        }
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
        // Keyed by node, so a fresh tree starts packed.
        unpacked = []
        enclosing = enclosingFolders(of: tree.path)
        scannedDisk = isVolumeRoot(tree.path)
        // A folder gone since the last scan lands on what is left of its path.
        current = wasAt.flatMap { find($0, in: tree, orNearest: true) } ?? tree
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
            scan(root.path, remembering: false)
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
            unpacked: unpacked, free: freeSpace(of: current, for: size))
        if let cache = layoutCache, cache.key == key {
            return cache.tiles
        }
        let tiles = tiles(of: current, for: size)
        layoutCache = (key, tiles)
        return tiles
    }

    /// Any folder's mosaic, uncached: for the view being zoomed away from.
    func tiles(of node: Node, for size: CGSize) -> [Tile] {
        var options = LayoutOptions()
        options.unpacked = unpacked
        let area = diskSplit(of: node, for: size)?.used ?? CGRect(origin: .zero, size: size)
        return layout(node, in: area, options: options)
    }

    var canShowFreeSpace: Bool {
        scannedDisk && current === root
    }

    func freeSpace(of node: Node, for size: CGSize) -> FreeSpace? {
        diskSplit(of: node, for: size)?.free
    }

    /// Only the disk's own mosaic has room for its free space, sized like a tile.
    private func diskSplit(of node: Node, for size: CGSize) -> (used: CGRect, free: FreeSpace)? {
        guard showsFreeSpace, scannedDisk, node === root, let disk, disk.available > 0 else {
            return nil
        }
        let used = Double(node.bytes)
        let free = Double(disk.available)
        // Largest first, as squarify expects.
        let rects = squarify(
            [max(used, free), min(used, free)], in: CGRect(origin: .zero, size: size))
        let (usedRect, freeRect) = used >= free ? (rects[0], rects[1]) : (rects[1], rects[0])
        return (usedRect, FreeSpace(rect: freeRect, bytes: disk.available))
    }

    /// Going back up to where you came from always works, even into a
    /// folder that is hidden now.
    func canOpen(_ node: Node) -> Bool {
        guard node.isDir, !node.children.isEmpty else {
            return false
        }
        return !node.hidesContents || unpacked.contains(ObjectIdentifier(node))
            || current?.isDescendant(of: node) == true
    }

    /// Opens a block in place; the next double-click opens it for real.
    func unpack(_ node: Node) {
        unpacked.insert(ObjectIdentifier(node))
    }

    func pack(_ nodes: [Node]) {
        unpacked.subtract(nodes.map(ObjectIdentifier.init))
    }

    func open(_ node: Node) {
        guard canOpen(node), node !== current else {
            return
        }
        remember()
        current = node
        selected = nil
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
        remember()
        selected = .node(current)
        self.current = parent
    }

    /// Back to where you were, rescanning it if it was in another scan.
    func goBack() {
        guard let path = history.popLast() else {
            return
        }
        guard let root, let node = find(path, in: root) else {
            scan(path, showing: path, remembering: false)
            return
        }
        current = node
        selected = nil
        hovered = nil
    }

    private func remember() {
        if let current {
            history.append(current.path)
        }
    }

    /// A file opens in its app, as from Finder.
    func launch(_ node: Node) {
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }

    func revealInFinder(_ node: Node) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func canTrash(_ node: Node) -> Bool {
        node !== root && !isHomeDirectory(node.path) && !node.isMountPoint && !node.isInTrash
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
        root.flatMap { find(trashPath, in: $0) }
    }

    private var trashPath: String { NSHomeDirectory() + "/.Trash" }

    /// Through Finder, which knows every volume's Trash and needs no Full
    /// Disk Access; the first time, macOS asks to let MacTree control Finder.
    func emptyTrash() {
        emptyingTrash = true
        Task {
            let failure = await askFinder(["empty trash"])
            emptyingTrash = false
            if let failure {
                error = "Could not empty the Trash: \(failure)"
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

    /// Finder's own Info window; there is no API for it but Finder's.
    func getInfo(_ node: Node) {
        Task {
            let failure = await askFinder(
                ["activate", "open information window of (POSIX file (item 1 of argv) as alias)"],
                argument: node.path)
            if let failure {
                error = "Could not show info for \u{201C}\(node.displayName)\u{201D}: \(failure)"
            }
        }
    }

    /// Runs `lines` inside `tell application "Finder"`, with `argument` as
    /// `item 1 of argv` so paths never become script text. Returns the error.
    private func askFinder(_ lines: [String], argument: String? = nil) async -> String? {
        let script = ["on run argv", "tell application \"Finder\""] + lines + ["end tell", "end run"]
        let arguments = script.flatMap { ["-e", $0] } + [argument].compactMap { $0 }
        return await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : String(decoding: message, as: UTF8.self)
        }.value
    }

    /// Walks our own tree by name, so no path string is parsed from outside.
    /// Firmlinked spellings of a path are equal.
    private func find(_ path: String, in tree: Node, orNearest: Bool = false) -> Node? {
        let base = canonicalPath(tree.path)
        let target = canonicalPath(path)
        guard target == base || target.hasPrefix(base + "/") else {
            return nil
        }
        var node = tree
        for part in target.dropFirst(base.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else {
                return orNearest ? node : nil
            }
            node = next
        }
        return node
    }
}
