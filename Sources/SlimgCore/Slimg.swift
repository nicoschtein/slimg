import Foundation

public enum ImageFormat: String, Sendable {
    case jpeg
    case png
    case gif
    case heic
    case unknown
}

/// Options controlling what gets removed. Defaults are fully lossless:
/// pixels are never altered, only ancillary data that does not affect
/// how the image renders is stripped.
public struct OptimizationOptions: Sendable {
    /// Remove EXIF, XMP, IPTC, comments, timestamps and similar metadata.
    public var stripMetadata: Bool
    /// Keep embedded ICC color profiles (and PNG color chunks). Stripping these
    /// can shift colors, so they are kept by default to stay visually lossless.
    public var keepColorProfile: Bool
    /// Re-compress losslessly (PNG zlib re-deflate at maximum level).
    public var recompress: Bool

    /// Try additional reversible PNG filters and zlib compression strategies.
    public var pngDeepCompression: Bool
    /// Spend extra CPU on Zopfli compression of unchanged PNG scanline bytes.
    public var pngZopfli: Bool
    /// Use a smaller PNG representation only when every sample is preserved.
    public var pngReduceRepresentation: Bool
    /// Consolidate PNG image chunks and recompress retained profiles losslessly.
    public var pngOptimizeStructure: Bool
    /// Optimize JPEG entropy coding without changing quantized coefficients.
    public var jpegOptimizeHuffman: Bool
    /// Try progressive JPEG scan coding without changing quantized coefficients.
    public var jpegProgressive: Bool
    /// Recompress GIF image indices without changing frames or color tables.
    public var gifRecompress: Bool

    public init(stripMetadata: Bool = true, keepColorProfile: Bool = true, recompress: Bool = true,
                pngDeepCompression: Bool = false, pngZopfli: Bool = false, pngReduceRepresentation: Bool = false,
                pngOptimizeStructure: Bool = false, jpegOptimizeHuffman: Bool = false,
                jpegProgressive: Bool = false, gifRecompress: Bool = false) {
        self.stripMetadata = stripMetadata
        self.keepColorProfile = keepColorProfile
        self.recompress = recompress
        self.pngDeepCompression = pngDeepCompression
        self.pngZopfli = pngZopfli
        self.pngReduceRepresentation = pngReduceRepresentation
        self.pngOptimizeStructure = pngOptimizeStructure
        self.jpegOptimizeHuffman = jpegOptimizeHuffman
        self.jpegProgressive = jpegProgressive
        self.gifRecompress = gifRecompress
    }
}

/// What kind of data an item that was removed (or shrunk) represents.
/// Lets UIs pick icons/wording and lets callers reason about the change.
public enum RemovalKind: String, Sendable {
    case exif          // EXIF camera/device metadata
    case xmp           // Adobe XMP metadata
    case iptc          // IPTC / Photoshop metadata
    case colorProfile  // ICC color profile (only removed if explicitly requested)
    case comment       // free-text comment
    case timestamp     // embedded modification time
    case textMetadata  // generic text chunk
    case appData       // other application-specific metadata
    case recompression // lossless re-compression of image data (no data lost)
    case other

    public var isColorAffecting: Bool { self == .colorProfile }
}

/// One line of the advanced report: a thing that was removed or shrunk.
public struct RemovedItem: Sendable, Identifiable {
    public let id = UUID()
    public let kind: RemovalKind
    public let label: String
    public let bytes: Int

    public init(kind: RemovalKind, label: String, bytes: Int) {
        self.kind = kind
        self.label = label
        self.bytes = bytes
    }
}

/// The advanced report: everything stripped or shrunk, with byte counts.
public struct OptimizationReport: Sendable {
    public let items: [RemovedItem]

    public init(items: [RemovedItem]) { self.items = items }

    public static let empty = OptimizationReport(items: [])

    public var isEmpty: Bool { items.isEmpty }
    /// Total bytes attributable to the listed items.
    public var bytesAccounted: Int { items.reduce(0) { $0 + $1.bytes } }
    /// Just the metadata removals (excludes lossless recompression).
    public var metadataItems: [RemovedItem] { items.filter { $0.kind != .recompression } }
    public var metadataBytes: Int { metadataItems.reduce(0) { $0 + $1.bytes } }
}

public struct OptimizationResult: Sendable {
    public let data: Data
    public let format: ImageFormat
    public let originalSize: Int
    public let optimizedSize: Int
    public let report: OptimizationReport

    public var changed: Bool { optimizedSize < originalSize }
    public var savedBytes: Int { max(0, originalSize - optimizedSize) }
    public var savedFraction: Double {
        originalSize > 0 ? Double(savedBytes) / Double(originalSize) : 0
    }
}

/// Internal result produced by each format optimizer.
struct OptimizerOutput {
    let bytes: [UInt8]
    let items: [RemovedItem]
}

public enum Slimg {
    /// Detect the image format from its magic bytes.
    public static func detectFormat(_ data: Data) -> ImageFormat {
        let b = [UInt8](data.prefix(8))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return .png }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38,
           (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61 { return .gif }
        if HEICOptimizer.isHEIC(data) { return .heic }
        return .unknown
    }

    /// Optimize image data losslessly. Never returns data larger than the input,
    /// and never alters pixel values. The result carries an advanced report
    /// describing exactly what was removed.
    public static func optimize(_ data: Data, options: OptimizationOptions = .init()) -> OptimizationResult {
        let bytes = [UInt8](data)
        let format = detectFormat(data)

        let output: OptimizerOutput?
        switch format {
        case .jpeg: output = JPEGOptimizer.optimize(bytes, options: options)
        case .png:  output = PNGOptimizer.optimize(bytes, options: options)
        case .gif:  output = GIFOptimizer.optimize(bytes, options: options)
        case .heic: output = HEICOptimizer.optimize(data, options: options)
        case .unknown: output = nil
        }

        // Safety net: never grow the file. If an optimizer produced nothing
        // smaller (or bailed out), fall back to the original bytes untouched.
        let finalBytes: [UInt8]
        let report: OptimizationReport
        if let output, output.bytes.count < bytes.count {
            finalBytes = output.bytes
            report = OptimizationReport(items: output.items)
        } else {
            finalBytes = bytes
            report = .empty
        }

        return OptimizationResult(
            data: Data(finalBytes),
            format: format,
            originalSize: bytes.count,
            optimizedSize: finalBytes.count,
            report: report
        )
    }
}
