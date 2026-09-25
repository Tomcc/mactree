import AppKit
import MacTreeCore
import SwiftUI

// `MacTree --snapshot out.png [path]` scans, renders one frame to a PNG and
// exits: a way to check the look and the numbers without a screen.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    let output = arguments[flag + 1]
    let path = arguments.count > flag + 2 ? arguments[flag + 2] : NSHomeDirectory()
    MainActor.assumeIsolated {
        exit(Snapshot.render(path: path, to: output))
    }
}
MacTreeApp.main()

struct MacTreeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("mactree") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .ignoresSafeArea()
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(action: handleKey)
                .onAppear {
                    if case .idle = model.phase {
                        model.scan(startPath)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { chooseFolder() }.keyboardShortcut("o")
                Button("Scan Whole Disk") { model.scan("/System/Volumes/Data") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Rescan") { model.rescan() }.keyboardShortcut("r")
            }
        }
    }

    /// `-path <dir>` on the command line, or the home folder. AppKit reads
    /// `-key value` as a default; a bare path would be a file to open, and
    /// SwiftUI then skips the main window.
    private var startPath: String {
        UserDefaults.standard.string(forKey: "path").map { ($0 as NSString).standardizingPath }
            ?? NSHomeDirectory()
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch (press.key, press.modifiers) {
        case (.return, _):
            if let node = model.selected {
                model.open(node)
            }
        case (.delete, .command):
            if let node = model.selected, model.trashRefusal(node) == nil {
                model.pendingTrash = node
            }
        case (.delete, _), (.escape, _):
            model.up()
        case ("[", _):
            model.changeDepth(by: -1)
        case ("]", _):
            model.changeDepth(by: 1)
        default:
            return .ignored
        }
        return .handled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(url.path)
        }
    }
}

/// A bare executable (`swift run`) starts as a background process with no
/// Dock icon and no key window; this makes it a normal app either way.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
enum Snapshot {
    static func render(path: String, to output: String) -> Int32 {
        let model = AppModel()
        model.scanBlocking(path)
        guard let root = model.root, let scan = model.lastScan else {
            return 1
        }
        print(
            "scanned \(root.path): \(root.bytes) bytes, \(root.files) files, "
                + "\(root.dirs) dirs, \(root.unreadable) unreadable, "
                + "\(scan.entries) entries in \(String(format: "%.2f", scan.seconds)) s")
        let renderer = ImageRenderer(
            content: ContentView(model: model).frame(width: 1440, height: 920))
        renderer.scale = 2
        guard let image = renderer.cgImage,
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
        else {
            print("could not render")
            return 1
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? 0 : 1
    }
}
