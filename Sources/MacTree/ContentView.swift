import MacTreeCore
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            Divider().overlay(Theme.line.color)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    StatsRow(model: model)
                    main
                }
                SidePanel(model: model)
                    .frame(width: 300)
            }
            Divider().overlay(Theme.line.color)
            Footer(model: model)
        }
        .background(Theme.background.color)
        .foregroundStyle(Theme.foreground.color)
        .preferredColorScheme(.dark)
        .alert(
            "Move \u{201C}\(model.pendingTrash?.displayName ?? "")\u{201D} to the Trash?",
            isPresented: Binding(
                get: { model.pendingTrash != nil },
                set: {
                    if !$0 {
                        model.pendingTrash = nil
                    }
                }),
            presenting: model.pendingTrash
        ) { node in
            Button("Move to Trash", role: .destructive) { model.trash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("\(formatBytes(node.bytes)) · \(formatCount(node.files)) files\n\(node.path)")
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
            Color.clear
        case .scanning(let path, let started):
            ScanningView(path: path, entries: model.scannedEntries, started: started)
        case .ready:
            TreemapView(model: model)
                .padding([.leading, .bottom, .trailing], 8)
        }
    }
}

private struct ScanningView: View {
    let path: String
    let entries: Int
    let started: Date

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Scanning \(path)").foregroundStyle(Theme.bright.color)
            TimelineView(.periodic(from: started, by: 0.2)) { context in
                let seconds = context.date.timeIntervalSince(started)
                Text("\(formatCount(entries)) entries · \(String(format: "%.1f", seconds)) s")
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inset.color)
    }
}

private struct Header: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Logo()
            Text("mactree").font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.bright.color)
            Breadcrumbs(model: model)
            Spacer()
            DepthStepper(model: model)
        }
        // Room for the traffic lights, which sit over the hidden title bar.
        .padding(.leading, 80)
        .padding(.trailing, 16)
        .frame(height: 52)
    }
}

private struct Logo: View {
    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Palette.accent(.code).color.frame(width: 8, height: 8)
                Palette.accent(.agentScratch).color.frame(width: 8, height: 8)
            }
            GridRow {
                Palette.accent(.toolchain).color.frame(width: 8, height: 8)
                Palette.accent(.synced).color.frame(width: 8, height: 8)
            }
        }
    }
}

private struct Breadcrumbs: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if let current = model.current {
                ForEach(current.ancestry, id: \.path) { node in
                    Text("/").foregroundStyle(Theme.muted.color)
                    Button(node.displayName) { model.open(node) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            node === current ? Theme.line.color : .clear,
                            in: .rect(cornerRadius: 4))
                        .foregroundStyle(
                            node === current ? Theme.bright.color : Theme.foreground.color)
                }
            }
        }
        .font(.system(size: 14))
    }
}

private struct DepthStepper: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Depth \(model.depth)").monospacedDigit()
            Button("−") { model.changeDepth(by: -1) }.buttonStyle(.plain)
            Button("+") { model.changeDepth(by: 1) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line.color))
        .foregroundStyle(Theme.bright.color)
    }
}

private struct StatsRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let current = model.current {
                Text(formatBytes(current.bytes)).foregroundStyle(Theme.bright.color)
                Text("· \(formatCount(current.files)) files · \(formatCount(current.dirs)) dirs")
                if current.unreadable > 0 {
                    Text("· \(formatCount(current.unreadable)) unreadable")
                        .foregroundStyle(Theme.warning.color)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                HatchSwatch()
                Text("Reclaimable")
            }
            ForEach(Kind.legend, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accent(kind).color)
                        .frame(width: 10, height: 10)
                    Text(kind.label)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

private struct HatchSwatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.line.color))
            var lines = Path()
            for x in stride(from: -size.height, to: size.width, by: 3) {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(lines, with: .color(Theme.foreground.color.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: 10, height: 10)
        .clipShape(.rect(cornerRadius: 2))
    }
}

private struct Footer: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Key("double-click", "open")
            Key("⌫", "up")
            Key("[ ]", "depth")
            Key("⌘R", "rescan")
            Key("⌘⌫", "trash")
            Spacer()
            if let hovered = model.hovered {
                Text(hovered.path).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(Theme.muted.color)
            } else if let scan = model.lastScan {
                let seconds = String(format: "%.1f", scan.seconds)
                Text("scan \(formatCount(scan.entries)) entries · \(seconds) s")
                    .foregroundStyle(Theme.muted.color)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

private struct Key: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line.color))
                .foregroundStyle(Theme.bright.color)
            Text(label)
        }
    }
}
