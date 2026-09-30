import AppKit
import MacTreeCore
import SwiftUI

/// Finder's "Computer": every mounted volume, plus Home and any folder.
struct ComputerView: View {
    let scan: (String) -> Void
    let chooseFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [Volume] = []
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasFullDiskAccess {
                AccessRequest()
                Divider()
            }
            List {
                Section("Volumes") {
                    ForEach(volumes) { volume in
                        Button {
                            pick(volume.scanPath)
                        } label: {
                            VolumeRow(volume: volume)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Folders") {
                    Button {
                        pick(NSHomeDirectory())
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Choose Folder…") {
                    dismiss()
                    chooseFolder()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 460, height: hasFullDiskAccess ? 380 : 470)
        .onAppear { volumes = Volume.mounted() }
        // Granted in System Settings while the sheet is up.
        .task {
            while !hasFullDiskAccess && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                hasFullDiskAccess = FullDiskAccess.isGranted
            }
        }
    }

    private func pick(_ path: String) {
        dismiss()
        scan(path)
    }
}

/// Without Full Disk Access, macOS hides the Trash, Mail and much of ~/Library from every app.
private struct AccessRequest: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 6) {
                Text("MacTree needs Full Disk Access").font(.headline)
                Text("to see inside the Trash, ~/Library and other private folders")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings", action: FullDiskAccess.openSettings)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VolumeRow: View {
    let volume: Volume

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: volume.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                    .controlSize(.small)
                Text("\(formatBytes(volume.available)) available of \(formatBytes(volume.total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct Volume: Identifiable {
    let id: URL
    let name: String
    let icon: NSImage
    let available: UInt64
    let total: UInt64
    /// The boot volume's files live on its data volume; "/" is the sealed OS.
    let scanPath: String

    var used: UInt64 { total - min(available, total) }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let total = values.volumeTotalCapacity
            else {
                return nil
            }
            let data = "/System/Volumes/Data"
            let isBoot = url.path == "/" && FileManager.default.fileExists(atPath: data)
            return Volume(
                id: url, name: values.volumeName ?? url.lastPathComponent,
                icon: NSWorkspace.shared.icon(forFile: url.path),
                available: UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0),
                total: UInt64(total), scanPath: isBoot ? data : url.path)
        }
    }
}
