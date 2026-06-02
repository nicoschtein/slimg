import AppKit
import Foundation
import SlimgCore
import UniformTypeIdentifiers

@MainActor
final class OptimizerModel: ObservableObject {
    enum Status: Equatable {
        case pending
        case processing
        case done
        case skipped(String)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var originalSize: Int
        var optimizedSize: Int?
        var format: ImageFormat = .unknown
        var status: Status = .pending
        var report: OptimizationReport?
    }

    @Published var items: [Item] = []

    // Settings (lossless defaults).
    @Published var stripMetadata = true
    @Published var keepColorProfile = true
    @Published var recompress = true
    // On (default): back up the original as name.bak.ext and write the
    // optimized image under the original name. Off: overwrite in place.
    @Published var keepOriginals = true

    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif"]

    var totalOriginal: Int { items.compactMap { $0.optimizedSize != nil ? $0.originalSize : nil }.reduce(0, +) }
    var totalOptimized: Int { items.compactMap { $0.optimizedSize }.reduce(0, +) }
    var totalSaved: Int { max(0, totalOriginal - totalOptimized) }
    var totalSavedFraction: Double { totalOriginal > 0 ? Double(totalSaved) / Double(totalOriginal) : 0 }

    // MARK: - Input

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .gif]
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func addURLs(_ urls: [URL]) {
        let expanded = urls.flatMap { expand($0) }
        for url in expanded {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let item = Item(url: url, originalSize: size)
            items.append(item)
            process(itemID: item.id)
        }
    }

    func clear() {
        items.removeAll()
    }

    private func expand(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
            return en.compactMap { $0 as? URL }.filter { isSupported($0) }
        }
        return isSupported(url) ? [url] : []
    }

    private func isSupported(_ url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Processing

    private func process(itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].status = .processing
        let url = items[idx].url
        let options = OptimizationOptions(
            stripMetadata: stripMetadata,
            keepColorProfile: keepColorProfile,
            recompress: recompress
        )
        let keepOriginals = self.keepOriginals

        Task.detached(priority: .userInitiated) {
            let outcome = Self.run(url: url, options: options, keepOriginals: keepOriginals)
            await MainActor.run { self.apply(outcome, to: itemID) }
        }
    }

    private enum Outcome {
        case done(optimizedSize: Int, format: ImageFormat, report: OptimizationReport)
        case skipped(String, format: ImageFormat)
        case failed(String)
    }

    private nonisolated static func run(url: URL, options: OptimizationOptions, keepOriginals: Bool) -> Outcome {
        guard let data = try? Data(contentsOf: url) else {
            return .failed("Cannot read file")
        }
        let result = Slimg.optimize(data, options: options)
        if result.format == .unknown {
            return .skipped("Unsupported format", format: .unknown)
        }
        guard result.changed else {
            return .skipped("Already optimal", format: result.format)
        }
        do {
            if keepOriginals {
                // Preserve the original as name.bak.ext. Never clobber an
                // existing backup (protects the true original on re-runs).
                let backup = backupURL(for: url)
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try data.write(to: backup, options: .atomic)
                }
            }
            // The optimized image always keeps the original filename.
            try result.data.write(to: url, options: .atomic)
            return .done(optimizedSize: result.optimizedSize, format: result.format, report: result.report)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func backupURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let name = ext.isEmpty ? "\(base).bak" : "\(base).bak.\(ext)"
        return dir.appendingPathComponent(name)
    }

    private func apply(_ outcome: Outcome, to itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        switch outcome {
        case let .done(optimizedSize, format, report):
            items[idx].optimizedSize = optimizedSize
            items[idx].format = format
            items[idx].report = report
            items[idx].status = .done
        case let .skipped(reason, format):
            items[idx].optimizedSize = items[idx].originalSize
            items[idx].format = format
            items[idx].status = .skipped(reason)
        case let .failed(message):
            items[idx].status = .failed(message)
        }
    }
}
