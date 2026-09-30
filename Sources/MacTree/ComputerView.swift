import AppKit
import MacTreeCore
import SwiftUI

/// Finder's "Computer": every mounted volume, plus Home and any folder.
struct ComputerView: View {
    let scan: (String) -> Void
    let chooseFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [Volume] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .frame(width: 460, height: 380)
        .onAppear { volumes = Volume.mounted() }
    }

    private func pick(_ path: String) {
        dismiss()
        scan(path)
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
