import Darwin
import Foundation

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

    /// What the kind means for deleting, for the legend's tooltips.
    public var summary: String {
        switch self {
        case .reclaimable:
            "Temporary or generated files that could be safe to delete"
        case .git:
            "Files tracked by Git that could be restored"
        case .app:
            "Apps installed on your Mac"
        case .system:
            "System or toolchain files that shouldn\u{2019}t be deleted without advanced knowledge"
        case .other:
            "Your own files, with no copy elsewhere that MacTree knows of."
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

/// Folders Finder shows as files. Launch Services knows the full set, but
/// only inside an app bundle, so this is the common part of it.
private let packageExtensions: Set<String> = [
    "app", "appex", "bundle", "component", "driver", "framework", "kext", "mdimporter",
    "plugin", "prefpane", "qlgenerator", "saver", "systemextension", "vst", "vst3", "xpc",
    "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
    "fcpbundle", "logicx", "band", "pages", "numbers", "key", "rtfd", "sparsebundle",
    "xcodeproj", "xcworkspace", "xcarchive", "dsym", "docset", "playground",
]

func isPackageName(_ name: String) -> Bool {
    packageExtensions.contains((name as NSString).pathExtension.lowercased())
}

/// Top-down: why each node's space can be had back, inherited downwards.
/// Runs before git, which has nothing to say about reclaimable space. A
/// package's insides are its own business: a Photos library's caches are
/// not to be cleared by hand.
func markReclaim(_ node: Node, inPackage: Bool = false) {
    let names = Set(node.children.map(\.name))
    for child in node.children {
        child.isPackage = child.isDir && isPackageName(child.name)
        child.reclaim = node.reclaim
        if child.isDir && child.reclaim == nil && !inPackage {
            child.reclaim = reclaim(
                ofName: child.name, parentName: node.displayName, hasSibling: names.contains)
        }
        markReclaim(child, inPackage: inPackage || child.isPackage)
    }
}

/// Top-down; a node inherits its parent's kind unless it says more itself.
/// Needs `reclaim` and `tracked` marked first.
func classify(_ root: Node) {
    root.kind = .other
    classifyChildren(of: root, kind: .other, volumeRoot: isVolumeRoot(root.path))
    sumReclaimable(root)
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
            && (child.name.hasPrefix(".") || volumeRoot && systemNames.contains(child.name)
                || child.name == "Library" && isHome(node))
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
private func sumReclaimable(_ node: Node) -> UInt64 {
    node.reclaimableBytes = node.kind == .reclaimable
        ? node.bytes : node.children.reduce(0) { $0 + sumReclaimable($1) }
    return node.reclaimableBytes
}

/// A user's home: the scanned home itself, or a folder in `Users`.
private func isHome(_ node: Node) -> Bool {
    node.parent?.displayName == "Users" || isHomeDirectory(node.path)
}

/// Less than this is no reason to open a System folder: a `.git` holds a
/// few kilobytes of LFS cache, which would otherwise lay it all out.
private let worthOpening: UInt64 = 10_000_000

extension Node {
    /// A System folder keeps its contents to itself, unless it holds real
    /// reclaimable space: there is nothing else to get back. A package
    /// always does: it is deleted whole, never in parts.
    public var hidesContents: Bool {
        isPackage || isTrash || kind == .system && reclaimableBytes < worthOpening
    }

    /// Finder's Trash: a home's `.Trash`, or a volume's `.Trashes`. Emptied whole.
    public var isTrash: Bool {
        isDir && (name == ".Trash" || name == ".Trashes")
    }

    /// The Trash or something in it: there is nowhere further to move it.
    public var isInTrash: Bool {
        ancestry.contains { $0.isTrash }
    }
}

/// Whether `path` is where a volume is mounted.
public func isVolumeRoot(_ path: String) -> Bool {
    var info = statfs()
    guard statfs(path, &info) == 0 else {
        return false
    }
    let mountPoint = withUnsafeBytes(of: info.f_mntonname) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return mountPoint == path
}
