import AppKit

/// `mactree [folder]` opens MacTree there: a script in ~/.local/bin, which
/// ~/.zshrc puts on the PATH.
enum CommandLineTool {
    static let pathLine = #"export PATH="$HOME/.local/bin:$PATH" # added by MacTree"#

    static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
            let executable = Bundle.main.executablePath
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Only an installed MacTree.app can add the command.",
            ])
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appending(path: "mactree")
        let script = "#!/bin/sh\nexec \(shellQuoted(executable)) --open \"${1:-.}\"\n"
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let zshrc = home.appending(path: ".zshrc")
        let existing = FileManager.default.fileExists(atPath: zshrc.path)
            ? try String(contentsOf: zshrc, encoding: .utf8) : ""
        // Our own line, so installing twice adds it once.
        guard !existing.split(separator: "\n").contains(Substring(pathLine)) else {
            return
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let handle = try FileHandle(forWritingTo: zshrc, creatingIfMissing: true)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((separator + pathLine + "\n").utf8))
    }

    /// Single-quoted for sh, so any path survives.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

private extension FileHandle {
    convenience init(forWritingTo url: URL, creatingIfMissing: Bool) throws {
        if creatingIfMissing, !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try self.init(forWritingTo: url)
    }
}
