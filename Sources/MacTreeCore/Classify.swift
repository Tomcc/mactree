// What a directory *is* (colour) and whether its space can be had back
// (hatch). Ported from disktree's classify.rs, plus the usual macOS names.

public enum Kind: CaseIterable, Sendable {
    case code, agentScratch, toolchain, synced, git, media, documents, cache
    case other

    /// What the legend lists, in its order.
    public static let legend: [Kind] = [
        .code, .agentScratch, .toolchain, .synced, .git, .media, .documents,
        .cache,
    ]

    public var label: String {
        switch self {
        case .code: "Code"
        case .agentScratch: "Agent scratch"
        case .toolchain: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

public enum Reclaim: Sendable {
    case regenerable, syncHistory, packageStore, buildOutput, reinstallable
    case sandboxLayers, snapshots, trash, temporary

    public var label: String {
        switch self {
        case .regenerable: "regenerable"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .sandboxLayers: "sandbox layers"
        case .snapshots: "snapshots"
        case .trash: "trash"
        case .temporary: "temporary"
        }
    }
}

public func kind(ofName name: String) -> Kind? {
    switch name.lowercased() {
    case "src", "code", "projects", "repos", "dev", "developer", "work",
        "workspace", "workspaces", "github.com", "gitlab.com", "sites",
        "development":
        return .code
    case ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini",
        ".continue", ".windsurf", ".microsandbox", ".omp", ".agents", ".openai",
        "tries", "worktrees", "experiments", "scratch", "playground":
        return .agentScratch
    case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun",
        ".deno", "go", ".gradle", ".m2", ".platformio", "mise", ".mise",
        ".pyenv", ".nvm", ".gem", "gem", ".rbenv", ".espressif", ".arduino15",
        ".config", ".vscode", ".zig", ".rye", ".conda", "anaconda3",
        "miniconda3", ".opam", ".ghcup", ".stack", ".julia", ".dotnet",
        ".android", ".sdkman", ".volta", ".yarn", ".java", ".swiftpm",
        "homebrew", "cellar", "xcode", "coresimulator", ".unity", "unity":
        return .toolchain
    case "sync", "dropbox", "nextcloud", "google drive", "onedrive",
        "pclouddrive", "mega", ".stversions", "mobile documents",
        "cloudstorage", "icloud drive":
        return .synced
    // App data: neutral, so a big `Caches` inside does not paint it all yellow.
    case "library", "application support", "containers", "group containers":
        return .other
    case ".git", ".git-lfs", "lfs":
        return .git
    case "pictures", "photos", "music", "videos", "movies", "steam", "models",
        ".ollama", ".lmstudio", "games", "wineprefix",
        "photos library.photoslibrary":
        return .media
    case "documents", "desktop", "downloads", "books", "notes", "obsidian",
        "public", "templates", "mail":
        return .documents
    case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache",
        "__pycache__", "node_modules", "trash", ".trash", "tmp", ".tmp",
        "deriveddata", "logs":
        return .cache
    default:
        return nil
    }
}

/// Judged from the name, the kind of the directory holding it, and its
/// siblings' names: `target` is only build output beside a `Cargo.toml`.
public func reclaim(
    ofName name: String, parent: Kind, hasSibling: (String) -> Bool
) -> Reclaim? {
    switch name.lowercased() {
    case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache":
        return .regenerable
    case ".stversions":
        return .syncHistory
    case ".pnpm-store", "pnpm":
        return .packageStore
    case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next",
        ".turbo", ".parcel-cache", "deriveddata":
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
    case "layers" where parent == .agentScratch:
        return .sandboxLayers
    case "snapshots" where parent == .agentScratch:
        return .snapshots
    case "trash", ".trash":
        return .trash
    case "tmp", ".tmp":
        return .temporary
    default:
        return nil
    }
}

/// Top-down: a node's own name wins, otherwise it inherits from its parent.
/// Reclaimable space is inherited too, so everything under a cache is hatched.
public func classify(_ root: Node) {
    root.kind = .other
    root.reclaim = nil
    let names = Set(root.children.map(\.name))
    for child in root.children {
        // An unknown top-level name takes its largest recognisable child's
        // kind: a checkout that is mostly `.git` reads as git.
        let childKind = kind(ofName: child.name)
            ?? (isGitStore(child) ? .git : nil)
            ?? dominantChildKind(child)
            ?? .other
        let childReclaim = child.isDir
            ? reclaim(ofName: child.name, parent: .other, hasSibling: names.contains)
            : nil
        classifyBelow(child, kind: childKind, reclaim: childReclaim)
    }
}

func classifyBelow(_ node: Node, kind: Kind, reclaim: Reclaim?) {
    node.kind = kind
    node.reclaim = reclaim
    guard !node.children.isEmpty else {
        return
    }
    let names = Set(node.children.map(\.name))
    for child in node.children {
        let childKind = child.isDir
            ? MacTreeCore.kind(ofName: child.name) ?? (isGitStore(child) ? .git : kind)
            : kind
        let childReclaim = reclaim ?? (child.isDir
            ? MacTreeCore.reclaim(
                ofName: child.name, parent: kind, hasSibling: names.contains)
            : nil)
        classifyBelow(child, kind: childKind, reclaim: childReclaim)
    }
}

/// The first recognisable name down the largest children, a few levels deep.
func dominantChildKind(_ node: Node) -> Kind? {
    var node = node
    for _ in 0..<3 {
        for child in node.children where child.isDir {
            if let found = kind(ofName: child.name) ?? (isGitStore(child) ? .git : nil) {
                return found
            }
        }
        guard let next = node.children.first(where: \.isDir) else {
            return nil
        }
        node = next
    }
    return nil
}

/// A git object store by its shape, whatever it is called.
func isGitStore(_ node: Node) -> Bool {
    guard node.isDir else {
        return false
    }
    let has = { (name: String) in node.children.contains { $0.name == name } }
    return has("objects") && has("refs") && has("HEAD")
}
