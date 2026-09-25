import MacTreeCore
import SwiftUI

struct SidePanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = model.selected, let root = model.root {
                Selection(node: node, root: root)
            }
            Divider().overlay(Theme.line.color).padding(.vertical, 18)
            if !model.worth.isEmpty {
                WorthALook(model: model, nodes: model.worth)
            }
            Spacer(minLength: 12)
            if let disk = model.disk {
                DiskSection(disk: disk)
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.color)
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased()).font(.system(size: 12)).tracking(0.6)
            .foregroundStyle(Theme.muted.color)
    }
}

private struct Selection: View {
    let node: Node
    let root: Node

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Selection")
            HStack(spacing: 10) {
                Palette.accent(node.kind).color.frame(width: 3, height: 24)
                Text(node.displayName).font(.system(size: 22)).lineLimit(1)
                    .foregroundStyle(Theme.bright.color)
            }
            .padding(.top, 16)
            Text(abbreviated(node.parent?.path ?? node.path)).font(.system(size: 12))
                .lineLimit(1).truncationMode(.head)
                .foregroundStyle(Theme.muted.color).padding(.top, 4)
            BigSize(bytes: node.bytes).padding(.top, 18)
            ShareBar(share: share, color: Theme.warning.color).padding(.top, 6)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 18) {
                GridRow {
                    Stat("Of scan", String(format: "%.0f%%", share * 100))
                    Stat("Files", formatCount(node.files))
                }
                GridRow {
                    Stat("Last write", lastWrite)
                    Stat("Kind", node.kind.label)
                }
            }
            .padding(.top, 22)
            if let reclaim = node.reclaim {
                Text("Reclaimable: \(reclaim.label)").font(.system(size: 13))
                    .foregroundStyle(Theme.warning.color).padding(.top, 14)
            }
        }
    }

    private var share: Double {
        root.bytes == 0 ? 0 : Double(node.bytes) / Double(root.bytes)
    }

    private var lastWrite: String {
        guard node.newest > 0 else {
            return "—"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(node.newest))
        return date.formatted(.relative(presentation: .named))
    }
}

private struct Stat: View {
    let caption: String
    let value: String

    init(_ caption: String, _ value: String) {
        self.caption = caption
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(caption)
            Text(value).font(.system(size: 16)).lineLimit(1)
                .foregroundStyle(Theme.bright.color)
        }
    }
}

private struct BigSize: View {
    let bytes: UInt64

    var body: some View {
        let parts = formatBytes(bytes).split(separator: " ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(parts.first ?? "").font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.bright.color)
            Text(parts.dropFirst().joined()).font(.system(size: 18))
                .foregroundStyle(Theme.muted.color)
        }
        .monospacedDigit()
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line.color)
                Capsule().fill(color)
                    .frame(width: max(geometry.size.width * min(share, 1), 3))
            }
        }
        .frame(height: 4)
    }
}

private struct WorthALook: View {
    let model: AppModel
    let nodes: [Node]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Caption("Worth a look")
                Spacer()
                Text(formatBytes(nodes.reduce(0) { $0 + $1.bytes }))
                    .font(.system(size: 13)).foregroundStyle(Theme.warning.color)
            }
            ForEach(nodes, id: \.path) { node in
                Button {
                    model.selected = node
                } label: {
                    row(node)
                }
                .buttonStyle(.plain)
                .contextMenu { NodeMenu(model: model, node: node) }
            }
        }
    }

    private func row(_ node: Node) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Palette.accent(node.kind).color.frame(width: 2, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(shortPath(node)).font(.system(size: 14)).lineLimit(1)
                    .truncationMode(.head).foregroundStyle(Theme.bright.color)
                Text(node.reclaim?.label ?? "").font(.system(size: 12))
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(formatBytes(node.bytes)).font(.system(size: 14)).monospacedDigit()
                    .foregroundStyle(Theme.bright.color)
                ShareBar(
                    share: Double(node.bytes) / Double(max(nodes[0].bytes, 1)),
                    color: Palette.accent(node.kind).color
                )
                .frame(width: 90)
            }
        }
        .contentShape(Rectangle())
    }

    /// The parent and the name: "tobi/.cache" says more than ".cache".
    private func shortPath(_ node: Node) -> String {
        guard let parent = node.parent else {
            return node.displayName
        }
        return parent.displayName + "/" + node.name
    }
}

private struct DiskSection: View {
    let disk: DiskSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Caption("Disk")
                Text(disk.volumeName).font(.system(size: 12))
                    .foregroundStyle(Theme.muted.color)
            }
            let parts = formatBytes(disk.available).split(separator: " ")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parts.first ?? "").font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.bright.color)
                Text("\(parts.dropFirst().joined()) available").font(.system(size: 15))
                    .foregroundStyle(Theme.muted.color)
            }
            .padding(.top, 12)
            ShareBar(
                share: Double(disk.total - disk.available) / Double(max(disk.total, 1)),
                color: Theme.muted.color
            )
            .padding(.top, 10)
            HStack {
                Text("\(formatBytes(disk.total - disk.available)) used")
                Spacer()
                Text("\(formatBytes(disk.total)) total")
            }
            .font(.system(size: 12)).padding(.top, 10)
        }
    }
}

private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
