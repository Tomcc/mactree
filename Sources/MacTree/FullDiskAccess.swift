import AppKit

/// Apps can't ask for Full Disk Access, only send people to System Settings to
/// grant it. Opening the TCC database is the usual test: nothing else unlocks it.
enum FullDiskAccess {
    static var isGranted: Bool {
        let database = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let file = open(database, O_RDONLY)
        guard file >= 0 else {
            return false
        }
        close(file)
        return true
    }

    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        // A literal, well-formed URL.
        NSWorkspace.shared.open(URL(string: pane)!)
    }
}
