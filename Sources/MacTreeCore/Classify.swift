import Darwin

// What a directory is, for colour: space that can be had back, git, the OS,
// or anything else. Reclaimable wins: a cache inside the system is a cache.

public enum Kind: CaseIterable, Sendable {
    case reclaimable, git, system, other

    /// What the legend lists, in its order.
    public static let legend: [Kind] = [.reclaimable, .git, .system]

    public var label: String {
        switch self {
        case .reclaimable: "Reclaimable"
        case .git: "Git"
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
    case "log", "logs", "diagnosticreports":
        return .logs
    default:
        return nil
    }
}

/// What the OS owns at the top of a volume.
private let systemNames: Set<String> = [
    "System", "Library", "private", "usr", "bin", "sbin", "cores", "opt",
    ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".MobileBackups",
]

/// Top-down; a node inherits its parent's kind unless its own name says more.
public func classify(_ root: Node) {
    root.kind = .other
    root.reclaim = nil
    classifyChildren(of: root, kind: .other, reclaim: nil, volumeRoot: isVolumeRoot(root.path))
}

private func classifyChildren(of node: Node, kind: Kind, reclaim: Reclaim?, volumeRoot: Bool) {
    let names = Set(node.children.map(\.name))
    for child in node.children {
        var childReclaim = reclaim
        var childKind = kind
        if child.isDir {
            childReclaim = reclaim ?? MacTreeCore.reclaim(
                ofName: child.name, parentName: node.displayName, hasSibling: names.contains)
            if childReclaim != nil {
                childKind = .reclaimable
            } else if child.name == ".git" || isGitStore(child) {
                childKind = .git
            } else if volumeRoot && systemNames.contains(child.name) {
                childKind = .system
            }
        }
        child.kind = childKind
        child.reclaim = childReclaim
        classifyChildren(of: child, kind: childKind, reclaim: childReclaim, volumeRoot: false)
    }
}

/// A git object store by its shape, whatever it is called.
func isGitStore(_ node: Node) -> Bool {
    guard node.isDir else {
        return false
    }
    let has = { (name: String) in node.children.contains { $0.name == name } }
    return has("objects") && has("refs") && has("HEAD")
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
