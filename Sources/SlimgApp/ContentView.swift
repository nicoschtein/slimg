import SlimgCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: OptimizerModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                if model.items.isEmpty {
                    DropZone(isTargeted: isTargeted)
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addURLs(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
            Text("Slimg")
                .font(.headline)
            Text("lossless image slimming")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Keep originals", isOn: $model.saveCopies)
                .toggleStyle(.switch)
                .help("Write optimized copies as name.min.ext instead of overwriting in place.")
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add Images", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var fileList: some View {
        List {
            ForEach(model.items) { item in
                ItemRow(item: item)
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if isTargeted {
                Color.accentColor.opacity(0.08)
                    .overlay(Text("Drop to add").font(.title3).foregroundStyle(.tint))
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.totalOptimized > 0 {
                Text("Saved \(ByteFormat.string(model.totalSaved))")
                    .fontWeight(.semibold)
                Text(String(format: "(%.1f%%)", model.totalSavedFraction * 100))
                    .foregroundStyle(.green)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(ByteFormat.string(model.totalOriginal)) → \(ByteFormat.string(model.totalOptimized))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Drag images here to strip metadata and extra weight")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.items.isEmpty {
                Button("Clear") { model.clear() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text("Drop images here")
                .font(.title2)
            Text("JPEG · PNG · GIF — pixels untouched, metadata removed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .padding(20)
        )
    }
}

private struct ItemRow: View {
    let item: OptimizerModel.Item
    @State private var showReport = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
            reportButton
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var reportButton: some View {
        if case .done = item.status, let report = item.report, !report.isEmpty {
            Button {
                showReport.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Show what was removed")
            .popover(isPresented: $showReport, arrowEdge: .bottom) {
                ReportView(item: item, report: report)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .pending, .processing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch item.status {
        case .pending: return "Queued"
        case .processing: return "Optimizing…"
        case .done:
            let opt = item.optimizedSize ?? item.originalSize
            return "\(ByteFormat.string(item.originalSize)) → \(ByteFormat.string(opt))"
        case let .skipped(reason): return reason
        case let .failed(message): return message
        }
    }

    @ViewBuilder private var trailing: some View {
        if case .done = item.status, let opt = item.optimizedSize, item.originalSize > 0 {
            let frac = Double(item.originalSize - opt) / Double(item.originalSize)
            Text(String(format: "−%.1f%%", frac * 100))
                .font(.callout.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(frac > 0 ? .green : .secondary)
        }
    }
}

struct ReportView: View {
    let item: OptimizerModel.Item
    let report: OptimizationReport

    private var saved: Int { item.originalSize - (item.optimizedSize ?? item.originalSize) }
    private var fraction: Double {
        item.originalSize > 0 ? Double(saved) / Double(item.originalSize) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced report")
                    .font(.headline)
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.format.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text("\(ByteFormat.string(item.originalSize)) → \(ByteFormat.string(item.optimizedSize ?? item.originalSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "saved %@ (%.1f%%)", ByteFormat.string(saved), fraction * 100))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                }
                .padding(.top, 2)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.items.sorted { $0.bytes > $1.bytes }) { entry in
                        ReportRow(item: entry)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260)

            Divider()
            Text("Pixels were not modified. This is a lossless change.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}

private struct ReportRow: View {
    let item: RemovedItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ReportIcon.symbol(for: item.kind))
                .frame(width: 18)
                .foregroundStyle(item.kind == .recompression ? AnyShapeStyle(.blue) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.callout)
                    .lineLimit(2)
                Text(item.kind == .recompression ? "recompressed losslessly" : "removed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(item.bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

enum ReportIcon {
    static func symbol(for kind: RemovalKind) -> String {
        switch kind {
        case .exif: return "camera"
        case .xmp: return "doc.richtext"
        case .iptc: return "tag"
        case .colorProfile: return "paintpalette"
        case .comment: return "text.bubble"
        case .timestamp: return "clock"
        case .textMetadata: return "text.alignleft"
        case .appData: return "shippingbox"
        case .recompression: return "arrow.down.right.and.arrow.up.left"
        case .other: return "minus.circle"
        }
    }
}

enum ByteFormat {
    static func string(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(n)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return idx == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[idx])
    }
}
