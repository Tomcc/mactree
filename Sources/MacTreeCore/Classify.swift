import Darwin

// What a node is, for colour: space that can be had back, tracked by git
// (so also in the cloud), the OS's or tools' own, or anything else.
// Reclaimable wins: a cache inside the system is a cache.

public enum Kind: CaseIterable, Sendable {
    case reclaimable, git, app, system, other

    /// What the legend lists, in its order.
    public static let legend: [Kind] = [.reclaimable, .git, .app, .system]

    public var label: String {
        switch self {
        case .reclaimable: "Reclaimable"
        case .git: "Git"
        case .app: "Apps"
        case .system: "System"
        case .other: "Other"
        }
    }
}

/// Why a directory's space can be had back.
public enum Reclaim: Sendable {
    case regenerable, syncHistory, packageStore, buildOutput, reinstallable, trash
    case temporary, logs

    public var label: String {
        switch self {
        case .regenerable: "cache"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .trash: "trash"
        case .temporary: "temporary files"
        case .logs: "logs"
        }
    }
}

/// Judged from the name, its parent's name, and its siblings' names: `target`
/// is only build output beside a `Cargo.toml`.
public func reclaim(
    ofName name: String, parentName: String, hasSibling: (String) -> Bool
) -> Reclaim? {
    switch name.lowercased() {
    case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", ".parcel-cache", ".turbo":
        return .regenerable
    case ".stversions":
        return .syncHistory
    case ".pnpm-store", ".npm", ".yarn":
        return .packageStore
    case ".next", "deriveddata":
        return .buildOutput
    case "target" where hasSibling("Cargo.toml"):
        return .buildOutput
    case ".build" where hasSibling("Package.swift"):
        return .buildOutput
    // Unity's import cache, beside the project's Assets folder.
    case "library" where hasSibling("Assets") && hasSibling("ProjectSettings"):
        return .buildOutput
    case "node_modules" where hasSibling("package.json"):
        return .reinstallable
    case "trash", ".trash", ".trashes":
        return .trash
    case "tmp", ".tmp", "temp", "temporaryitems":
        return .temporary
    // macOS's per-user temporary and cache folders live in /private/var/folders.
    case "folders" where parentName == "var":
        return .temporary
    // Not `.git/logs`: those are git's reflogs, history rather than logs.
    case "logs" where parentName == ".git":
        return nil
    case "log", "logs", "diagnosticreports":
        return .logs
    default:
        return nil
    }
}

/// What the OS owns at the top of a volume.
private let systemNames: Set<String> = [
    "System", "Library", "private", "usr", "bin", "sbin", "cores", "opt",
]

/// Top-down: why each node's space can be had back, inherited downwards.
/// Runs before git, which has nothing to say about reclaimable space.
func markReclaim(_ node: Node) {
    let names = Set(node.children.map(\.name))
    for child in node.children {
        child.reclaim = node.reclaim
        if child.isDir && child.reclaim == nil {
            child.reclaim = reclaim(
                ofName: child.name, parentName: node.displayName, hasSibling: names.contains)
        }
        markReclaim(child)
    }
}

/// Top-down; a node inherits its parent's kind unless it says more itself.
/// Needs `reclaim` and `tracked` marked first.
func classify(_ root: Node) {
    root.kind = .other
    classifyChildren(of: root, kind: .other, volumeRoot: isVolumeRoot(root.path))
    markHoldsReclaimable(root)
}

private func classifyChildren(of node: Node, kind: Kind, volumeRoot: Bool) {
    for child in node.children {
        let childKind: Kind
        if child.reclaim != nil {
            childKind = .reclaimable
        } else if child.isApp {
            childKind = .app
        } else if child.tracked {
            // Before System: a repository's `.github` is its own, not the OS's.
            childKind = .git
        } else if child.isDir
            && (child.name.hasPrefix(".") || volumeRoot && systemNames.contains(child.name))
        {
            childKind = .system
        } else {
            childKind = kind == .git ? .other : kind
        }
        child.kind = childKind
        classifyChildren(of: child, kind: childKind, volumeRoot: false)
    }
}

@discardableResult
private func markHoldsReclaimable(_ node: Node) -> Bool {
    var holds = node.kind == .reclaimable
    for child in node.children where markHoldsReclaimable(child) {
        holds = true
    }
    node.holdsReclaimable = holds
    return holds
}

extension Node {
    /// A System folder keeps its contents to itself, unless revealed or
    /// holding something reclaimable: there is nothing else to get back there.
    /// An app always does: it is deleted whole, never in parts.
    public func hidesContents(revealingSystem: Bool) -> Bool {
        !revealingSystem && (isApp || kind == .system && !holdsReclaimable)
    }
}

/// Whether `path` is where a volume is mounted.
func isVolumeRoot(_ path: String) -> Bool {
    var info = statfs()
    guard statfs(path, &info) == 0 else {
        return false
    }
    let mountPoint = withUnsafeBytes(of: info.f_mntonname) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return mountPoint == path
}
