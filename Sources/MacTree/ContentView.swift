import MacTreeCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            main
            Divider()
            StatusBar(model: model)
        }
        .navigationTitle(model.current?.displayName ?? "MacTree")
        .toolbar { toolbar }
        // The title is centred instead, as a principal item.
        .toolbar(removing: .title)
        .task { await model.watchFreeSpace() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: .openFolder)) {
            if let path = $0.object as? String {
                model.showingComputer = false
                model.scan(path)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.showingComputer }, set: { model.showingComputer = $0 })
        ) {
            ComputerView(scan: { model.scan($0) }, chooseFolder: chooseFolder)
        }
        .confirmationDialog(
            "Are you sure you want to permanently erase the items in the Trash?",
            isPresented: Binding(
                get: { model.confirmingEmptyTrash },
                set: { model.confirmingEmptyTrash = $0 })
        ) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("You can\u{2019}t undo this action.")
        }
        .alert(
            model.error ?? "",
            isPresented: Binding(
                get: { model.error != nil },
                set: {
                    if !$0 {
                        model.error = nil
                    }
                })
        ) {}
    }

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Nothing scanned yet", systemImage: "internaldrive")
            } actions: {
                Button("Choose a Disk or Folder…") { model.showingComputer = true }
            }
            // Fills the window, so the status bar stays at the bottom.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let path):
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning \((path as NSString).abbreviatingWithTildeInPath)…")
                Text("\(formatCount(model.scannedEntries)) items").foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            TreemapView(model: model)
                .padding(4)
        }
    }

    private var subtitle: String {
        guard let current = model.current else {
            return ""
        }
        return "\(formatBytes(current.bytes)) · \(formatCount(current.files)) files"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(model.current?.displayName ?? "MacTree").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .help("Go back to where you were")
            // Clear of the window's buttons, which the compact toolbar crowds.
            .padding(.leading, 12)
            .padding(.trailing, toolbarGap)
            .disabled(model.history.isEmpty)
            Button {
                model.up()
            } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .help("Go to the enclosing folder")
            .disabled(!model.canGoUp)
            .padding(.horizontal, toolbarGap)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: freeSpaceShown) {
                Label("Free Space", systemImage: "square.dashed")
            }
            .help("Show the disk\u{2019}s free space beside its contents")
            .disabled(!model.canShowFreeSpace)
            .padding(.horizontal, toolbarGap)
            Button {
                model.showingComputer = true
            } label: {
                Label("Computer", systemImage: "desktopcomputer")
            }
            .help("Scan a disk or another folder")
            .padding(.horizontal, toolbarGap)
            Button {
                model.rescan()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Scan again")
            .disabled(model.root == nil)
            .padding(.horizontal, toolbarGap)
            Button(role: .destructive) {
                model.confirmingEmptyTrash = true
            } label: {
                Label(emptyTrashTitle, systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.emptyingTrash)
            .padding(.leading, toolbarGap)
        }
    }

    /// Half the space between toolbar buttons, which otherwise touch.
    private var toolbarGap: CGFloat { 4 }

    private var freeSpaceShown: Binding<Bool> {
        Binding(get: { model.showsFreeSpace }, set: { model.showsFreeSpace = $0 })
    }

    /// The Trash's size, when the scan could read it.
    private var emptyTrashTitle: String {
        if model.emptyingTrash {
            return "Emptying…"
        }
        guard let trash = model.trashNode, !trash.unreadableHere else {
            return "Empty Trash"
        }
        return "Empty Trash (\(formatBytes(trash.bytes)))"
    }
}

/// Finder's path bar for what is under the pointer (or selected), the colour
/// legend, and how full the disk is.
private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            if let content = model.hovered ?? model.selected ?? model.current.map({ .node($0) }) {
                PathBar(model: model, node: content.owner)
                if case .others(_, _, let count) = content {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    Text(smallItemsTitle(count)).italic()
                }
                Text(formatBytes(content.bytes)).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                if let reclaim = content.node?.reclaim {
                    Text("· \(reclaim.label)").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Legend()
            if let disk = model.disk {
                DiskUsage(disk: disk).padding(.leading, 12)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

/// From the disk down to `node`. Folders above the scan rescan from there;
/// the rest just open.
private struct PathBar: View {
    let model: AppModel
    let node: Node

    private enum Crumb {
        case enclosing(Folder)
        case scanned(Node)
    }

    private var crumbs: [Crumb] {
        model.enclosing.map { .enclosing($0) }
            + node.ancestry.map { .scanned($0) }
    }

    var body: some View {
        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
            if index > 0 {
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
            }
            switch crumb {
            case .enclosing(let folder):
                Button {
                    model.scan(folder.path, showing: folder.path)
                } label: {
                    Label {
                        Text(folder.name)
                    } icon: {
                        CrumbIcon(image: Icons.shared.finderIcon(folder.path))
                    }
                }
                .buttonStyle(.plain)
            case .scanned(let node):
                Button {
                    model.open(node)
                } label: {
                    Label {
                        Text(node.displayName)
                    } icon: {
                        CrumbIcon(image: Icons.shared.icon(node))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Finder's icon for a crumb, at the size of the text beside it.
private struct CrumbIcon: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Kind.legend, id: \.self) { kind in
                Text(kind.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.color(kind)))
                    .help(kind.summary)
            }
        }
    }
}

private struct DiskUsage: View {
    let disk: DiskSpace

    var body: some View {
        let used = disk.total - min(disk.available, disk.total)
        HStack(spacing: 6) {
            ProgressView(value: Double(used), total: Double(max(disk.total, 1)))
                .frame(width: 70)
            Text("\(formatBytes(used)) of \(formatBytes(disk.total)) used")
                .monospacedDigit()
        }
        .help("\(formatBytes(disk.available)) available on \(disk.volumeName)")
    }
}
