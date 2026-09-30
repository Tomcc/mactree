import Foundation
import Synchronization

/// Marks the files each repository under `root` tracks, then every folder
/// whose files are all tracked: that space is also in the cloud. Returns a
/// line per repository git could not list.
func markTracked(_ root: Node) -> [String] {
    var repos: [Node] = []
    collectRepos(root, into: &repos)
    let listed = Mutex<[(repo: Node, paths: [String])]>([])
    let failures = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: repos.count) { index in
        let repo = repos[index]
        switch listTracked(repo.path) {
        case .success(let paths): listed.withLock { $0.append((repo, paths)) }
        case .failure(let error): failures.withLock { $0.append("\(repo.path): \(error)") }
        }
    }
    // Mutating nodes is not thread-safe, so the marking itself is serial.
    var lookup: [ObjectIdentifier: [String: Node]] = [:]
    for (repo, paths) in listed.withLock({ $0 }) {
        for path in paths {
            // A tracked file deleted from the work tree has no node; that is
            // an ordinary change, not an error.
            if let node = find(path, from: repo, lookup: &lookup), !node.isDir {
                node.tracked = true
            }
        }
    }
    markTrackedFolders(root)
    return failures.withLock { $0 }
}

/// Directories holding a `.git`: a folder for a repository, a file for a
/// submodule or a worktree. Reclaimable space is skipped: it shows as such
/// whatever git says, and caches hold `.git` markers that aren't repos.
private func collectRepos(_ node: Node, into repos: inout [Node]) {
    guard node.reclaim == nil else {
        return
    }
    if node.children.contains(where: { $0.name == ".git" }) {
        repos.append(node)
    }
    for child in node.children where child.isDir && child.name != ".git" {
        collectRepos(child, into: &repos)
    }
}

private struct GitError: Error, CustomStringConvertible {
    let description: String
}

private func listTracked(_ path: String) -> Result<[String], GitError> {
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", path, "ls-files", "-z"]
    let output = Pipe()
    let errors = Pipe()
    git.standardOutput = output
    git.standardError = errors
    do {
        try git.run()
    } catch {
        return .failure(GitError(description: error.localizedDescription))
    }
    // Read before waiting: a full pipe would block git forever.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    guard git.terminationStatus == 0 else {
        let text = String(decoding: message, as: UTF8.self)
        return .failure(GitError(description: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return .success(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
}

private func find(
    _ relative: String, from repo: Node, lookup: inout [ObjectIdentifier: [String: Node]]
) -> Node? {
    var node = repo
    for name in relative.split(separator: "/") {
        let id = ObjectIdentifier(node)
        if lookup[id] == nil {
            lookup[id] = Dictionary(node.children.map { ($0.name, $0) }) { first, _ in first }
        }
        guard let next = lookup[id]?[String(name)] else {
            return nil
        }
        node = next
    }
    return node
}

/// Bottom-up: a folder is tracked when it holds tracked files and nothing
/// else. Empty folders don't count either way; git can't track them.
@discardableResult
private func markTrackedFolders(_ node: Node) -> Bool {
    guard node.isDir else {
        return node.tracked
    }
    var all = true
    for child in node.children {
        let tracked = markTrackedFolders(child)
        if !tracked && !(child.isDir && child.files == 0) {
            all = false
        }
    }
    node.tracked = all && node.files > 0
    return node.tracked
}
