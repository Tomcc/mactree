import AppKit
import MacTreeCore
import SwiftUI

// `MacTree --snapshot out [path]` scans, renders out-light.png and
// out-dark.png and exits: a way to check the look without a screen.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    let output = arguments[flag + 1]
    let path = arguments.count > flag + 2 ? arguments[flag + 2] : NSHomeDirectory()
    MainActor.assumeIsolated {
        exit(Snapshot.render(path: path, to: output))
    }
}
// `MacTree --open [path]` is the `mactree` command: it shows `path` in the
// app, launching it or asking the running one, then exits.
if let flag = arguments.firstIndex(of: "--open") {
    exit(openInApp(arguments.count > flag + 1 ? arguments[flag + 1] : "."))
}
MacTreeApp.main()

extension Notification.Name {
    /// Posted by `mactree` to a running app; the object is the folder's path.
    static let openFolder = Notification.Name("com.tomcc.mactree.openFolder")
}

private func openInApp(_ argument: String) -> Int32 {
    let path = URL(fileURLWithPath: argument).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
    else {
        FileHandle.standardError.write(Data("mactree: not a folder: \(argument)\n".utf8))
        return 1
    }
    let app = Bundle.main.bundleURL
    guard app.pathExtension == "app" else {
        FileHandle.standardError.write(Data("mactree: run from inside MacTree.app\n".utf8))
        return 1
    }
    let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
    ).contains { $0.processIdentifier != getpid() }
    if running {
        DistributedNotificationCenter.default().postNotificationName(
            .openFolder, object: path, userInfo: nil, deliverImmediately: true)
    }
    // Launches with the path, or just brings the running app forward: macOS
    // may refuse to activate an app asked by a process that isn't frontmost.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", app.path, "--args", "-path", path]
    do {
        try open.run()
    } catch {
        FileHandle.standardError.write(Data("mactree: \(error.localizedDescription)\n".utf8))
        return 1
    }
    open.waitUntilExit()
    return open.terminationStatus
}

struct MacTreeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A `Window` scene never opened when launched from a shell.
        WindowGroup("MacTree") {
            ContentView(model: model, chooseFolder: chooseFolder)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    guard case .idle = model.phase else {
                        return
                    }
                    // Scanning a whole home folder takes a while: ask first,
                    // unless a folder was passed on the command line.
                    if let path = startPath {
                        model.scan(path)
                    } else {
                        model.showingComputer = true
                    }
                }
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Install Command Line Tool\u{2026}", action: installCommandLineTool)
            }
            CommandGroup(replacing: .newItem) {
                Button("Computer…") { model.showingComputer = true }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Choose Folder…", action: chooseFolder).keyboardShortcut("o")
                Divider()
                Button("Get Info") {
                    if let node = model.selected?.node {
                        model.getInfo(node)
                    }
                }
                .keyboardShortcut("i")
                .disabled(model.selected?.node == nil)
                Button("Move to Trash") {
                    if let node = model.selected?.node {
                        model.moveToTrash(node)
                    }
                }
                .keyboardShortcut(.delete)
                .disabled(model.selected?.node.map { !model.canTrash($0) } ?? true)
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(model.history.isEmpty)
                Button("Enclosing Folder") { model.up() }
                    .keyboardShortcut(.upArrow)
                    .disabled(!model.canGoUp)
                Button("Open Selection") {
                    if let node = model.selected?.owner {
                        model.open(node)
                    }
                }
                .keyboardShortcut(.downArrow)
                .disabled(model.selected.map { !model.canOpen($0.owner) } ?? true)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.rescan() }.keyboardShortcut("r")
                Toggle(
                    "Show Free Space",
                    isOn: Binding(
                        get: { model.showsFreeSpace }, set: { model.showsFreeSpace = $0 })
                )
                .disabled(!model.canShowFreeSpace)
            }
        }
    }

    /// `-path <dir>` on the command line. AppKit reads `-key value` as a
    /// default; a bare path would be a file to open, and SwiftUI then skips
    /// the main window.
    private var startPath: String? {
        UserDefaults.standard.string(forKey: "path").map { ($0 as NSString).standardizingPath }
    }

    private func installCommandLineTool() {
        do {
            try CommandLineTool.install()
        } catch {
            model.error = "Couldn\u{2019}t add the mactree command: \(error.localizedDescription)"
            return
        }
        let alert = NSAlert()
        alert.messageText = "mactree command added to your zsh PATH"
        alert.informativeText = "Restart your shell to use it."
        alert.runModal()
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
    static private(set) var isRendering = false

    static func render(path: String, to output: String) -> Int32 {
        isRendering = true
        let model = AppModel()
        let started = Date()
        model.scanBlocking(path)
        guard let root = model.root else {
            return 1
        }
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        print(
            "scanned \(root.path): \(root.bytes) bytes, \(root.files) files, "
                + "\(root.dirs) dirs, \(root.unreadable) unreadable in \(seconds) s")
        if let error = model.error {
            print("error: \(error)")
        }
        // A first render asks for the previews, which arrive asynchronously.
        _ = ImageRenderer(content: ContentView(model: model, chooseFolder: {})
            .frame(width: 1440, height: 900)).cgImage
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let content = ContentView(model: model, chooseFolder: {})
                .frame(width: 1440, height: 900)
                .background(Palette.background)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let url = URL(fileURLWithPath: "\(output)-\(suffix).png")
            guard let image = renderer.cgImage,
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil)
            else {
                print("could not render \(suffix)")
                return 1
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                return 1
            }
        }
        return 0
    }
}
