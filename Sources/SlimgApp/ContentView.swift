import SlimgCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: OptimizerModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                if model.items.isEmpty {
                    DropZone(isTargeted: isTargeted)
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
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
        HStack(spacing: 10) {
            BrandMark.gradient
                .frame(width: 22, height: 22)
            Text("Slimg")
                .font(.title3.weight(.bold))
                .tracking(-0.3)
            Text("lossless image slimming")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Keep originals", isOn: $model.keepOriginals)
                .toggleStyle(.switch)
                .tint(Brand.teal500)
                .help("Back up the original as name.bak.ext and save the optimized image under the original name. Off = overwrite in place.")
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add Images", systemImage: "plus")
            }
            .buttonStyle(.brandPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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
                ZStack {
                    Brand.gradient(opacity: 0.08)
                    Label("Drop to add", systemImage: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.teal500)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.totalOptimized > 0 {
                Text("Saved")
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(model.totalSaved))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(String(format: "(%.1f%%)", model.totalSavedFraction * 100))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Brand.success)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(ByteFormat.string(model.totalOriginal)) → \(ByteFormat.string(model.totalOptimized))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Drag images here to strip metadata and extra weight")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.items.isEmpty {
                Button("Clear") { model.clear() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.teal600)
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
        ZStack {
            // Faint brand watermark behind the prompt.
            BrandMark.mono(Brand.teal500.opacity(isTargeted ? 0.10 : 0.05))
                .frame(width: 220, height: 220)
                .blur(radius: isTargeted ? 0 : 0.5)

            VStack(spacing: 14) {
                BrandMark.gradient
                    .frame(width: 56, height: 56)
                    .opacity(isTargeted ? 1 : 0.9)
                    .scaleEffect(isTargeted ? 1.04 : 1)
                Text(isTargeted ? "Drop to slim them" : "Drop images to slim them")
                    .font(.title2.weight(.semibold))
                Text("JPEG · PNG · GIF · HEIC — pixels untouched, metadata removed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                )
                .padding(20)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(Brand.gradient(opacity: 0.05)) : AnyShapeStyle(Color.clear))
                .padding(20)
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private struct ItemRow: View {
    let item: OptimizerModel.Item
    @State private var showReport = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.body)
                .frame(width: 18)
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
        .padding(.vertical, 3)
    }

    @ViewBuilder private var reportButton: some View {
        if case .done = item.status, let report = item.report, !report.isEmpty {
            Button {
                showReport.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.teal600)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning)
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
                .foregroundStyle(frac > 0 ? AnyShapeStyle(Brand.success) : AnyShapeStyle(.secondary))
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BrandMark.gradient
                        .frame(width: 16, height: 16)
                    Text("Advanced report")
                        .font(.headline)
                }
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    BrandPill(text: item.format.rawValue.uppercased(), tinted: true)
                    Text("\(ByteFormat.string(item.originalSize)) → \(ByteFormat.string(item.optimizedSize ?? item.originalSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "saved %@ (%.1f%%)", ByteFormat.string(saved), fraction * 100))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Brand.success)
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
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Brand.teal500)
                Text("Pixels were not modified. This is a lossless change.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
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
                .foregroundStyle(item.kind == .recompression ? AnyShapeStyle(Brand.cyan500) : AnyShapeStyle(Brand.warning))
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
