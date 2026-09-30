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
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await model.watchFreeSpace() }
        .sheet(
            isPresented: Binding(
                get: { model.showingComputer }, set: { model.showingComputer = $0 })
        ) {
            ComputerView(scan: model.scan, chooseFolder: chooseFolder)
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
        ToolbarItem(placement: .navigation) {
            Button {
                model.up()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.backward")
            }
            .help("Go to the enclosing folder")
            .disabled(model.current?.parent == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showingComputer = true
            } label: {
                Label("Computer", systemImage: "desktopcomputer")
            }
            .help("Scan a disk or another folder")
            Button {
                model.rescan()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Scan again")
            .disabled(model.root == nil)
            Button(role: .destructive) {
                model.confirmingEmptyTrash = true
            } label: {
                Label(emptyTrashTitle, systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.emptyingTrash)
        }
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
            if let node = model.hovered ?? model.selected ?? model.current {
                ForEach(Array(node.ancestry.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    Button {
                        model.open(crumb)
                    } label: {
                        Label(crumb.displayName, systemImage: crumb.isDir ? "folder" : "doc")
                    }
                    .buttonStyle(.plain)
                }
                Text(formatBytes(node.bytes)).foregroundStyle(.secondary).padding(.leading, 6)
                if let reclaim = node.reclaim {
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

private struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Kind.legend, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.color(kind))
                        .frame(width: 9, height: 9)
                    Text(kind.label)
                }
            }
        }
        .foregroundStyle(.secondary)
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
