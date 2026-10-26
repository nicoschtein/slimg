import Foundation
import SlimgCore

func formatBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(n)
    var idx = 0
    while value >= 1024, idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    return idx == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[idx])
}

func printReport(_ result: OptimizationResult) {
    let report = result.report
    guard !report.isEmpty else {
        print("        (no removable metadata; saving came from structure only)")
        return
    }
    for item in report.items.sorted(by: { $0.bytes > $1.bytes }) {
        let verb = item.kind == .recompression ? "shrank " : "removed"
        print("        \(verb)  \(item.label)  (\(formatBytes(item.bytes)))")
    }
}

func printUsage() {
    let usage = """
    slimg — lossless image optimizer (strips metadata + extra weight)

    USAGE:
      slimg [options] <file> [<file> ...]

    OPTIONS:
      --dry-run            Report savings without writing any files.
      --backup             Keep the original as <name>.bak.<ext>; write the
                           optimized image under its original name.
      --report             Print an advanced breakdown of what was removed.
      --keep-metadata      Do not strip EXIF/XMP/IPTC/comments.
      --strip-color        Also strip ICC color profiles (except HEIC; may shift colors).
      --no-recompress      Skip lossless PNG re-compression.
      --deep-png           Try additional PNG filters and compression strategies.
      --zopfli-png         Try maximum PNG compression (much slower).
      --reduce-png         Reduce PNG color storage only when exactly lossless.
      --optimize-png       Combine PNG chunks and recompress retained profiles.
      --optimize-jpeg      Optimize JPEG Huffman coding without changing coefficients.
      --progressive-jpeg   Try progressive JPEG coding; keep only if smaller.
      --recompress-gif     Recompress GIF indices without changing animation.
      -h, --help           Show this help.

    Pixels are never altered. Output is never larger than the input.
    Supported formats: JPEG, PNG, GIF, HEIC/HEIF (HEVC images).
    Additional optimization methods are disabled unless explicitly requested.
    """
    print(usage)
}

var dryRun = false
var backup = false
var showReport = false
var options = OptimizationOptions()
var files = [String]()

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    printUsage()
    exit(0)
}

for arg in args {
    switch arg {
    case "--dry-run": dryRun = true
    case "--backup", "--copy": backup = true
    case "--report", "-v": showReport = true
    case "--keep-metadata": options.stripMetadata = false
    case "--strip-color": options.keepColorProfile = false
    case "--no-recompress": options.recompress = false
    case "--deep-png": options.pngDeepCompression = true
    case "--zopfli-png": options.pngZopfli = true
    case "--reduce-png": options.pngReduceRepresentation = true
    case "--optimize-png": options.pngOptimizeStructure = true
    case "--optimize-jpeg": options.jpegOptimizeHuffman = true
    case "--progressive-jpeg": options.jpegProgressive = true
    case "--recompress-gif": options.gifRecompress = true
    case "-h", "--help": printUsage(); exit(0)
    default:
        if arg.hasPrefix("-") {
            FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
            exit(2)
        }
        files.append(arg)
    }
}

guard !files.isEmpty else {
    printUsage()
    exit(0)
}

func backupURL(for url: URL) -> URL {
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    let dir = url.deletingLastPathComponent()
    let name = ext.isEmpty ? "\(base).bak" : "\(base).bak.\(ext)"
    return dir.appendingPathComponent(name)
}

var totalOriginal = 0
var totalOptimized = 0
var anyError = false

for path in files {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        FileHandle.standardError.write(Data("error: cannot read \(path)\n".utf8))
        anyError = true
        continue
    }

    let result = Slimg.optimize(data, options: options)
    totalOriginal += result.originalSize
    totalOptimized += result.optimizedSize

    let pct = String(format: "%.1f%%", result.savedFraction * 100)
    let formatTag = result.format.rawValue.uppercased()

    if result.format == .unknown {
        print("  skip  \(path) — unsupported format")
        continue
    }

    if !result.changed {
        print("  ----  \(path) [\(formatTag)] already optimal (\(formatBytes(result.originalSize)))")
        continue
    }

    if dryRun {
        print("  would \(path) [\(formatTag)] \(formatBytes(result.originalSize)) -> \(formatBytes(result.optimizedSize))  −\(pct)")
        if showReport { printReport(result) }
        continue
    }

    do {
        var note = ""
        if backup {
            // Preserve the original as name.bak.ext; never clobber an existing backup.
            let bak = backupURL(for: url)
            if !FileManager.default.fileExists(atPath: bak.path) {
                try data.write(to: bak, options: .atomic)
            }
            note = "(orig -> \(bak.lastPathComponent))"
        }
        // Optimized image always keeps the original filename. Atomic write so a
        // crash mid-write can never leave a half-written / corrupted original.
        try result.data.write(to: url, options: .atomic)
        print("  ok    \(path) [\(formatTag)] \(formatBytes(result.originalSize)) -> \(formatBytes(result.optimizedSize))  −\(pct) \(note)")
        if showReport { printReport(result) }
    } catch {
        FileHandle.standardError.write(Data("error: cannot write \(url.path): \(error.localizedDescription)\n".utf8))
        anyError = true
    }
}

if files.count > 1 {
    let saved = totalOriginal - totalOptimized
    let pct = totalOriginal > 0 ? Double(saved) / Double(totalOriginal) * 100 : 0
    print("")
    print(String(format: "Total: %@ -> %@  saved %@ (%.1f%%)",
                 formatBytes(totalOriginal), formatBytes(totalOptimized),
                 formatBytes(saved), pct))
}

exit(anyError ? 1 : 0)
