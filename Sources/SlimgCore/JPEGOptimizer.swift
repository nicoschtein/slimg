/// Lossless JPEG optimization: metadata stripping preserves scan bytes.
/// Optional entropy recoding preserves and verifies the native quantized DCT
/// coefficients, sampling, quantization and interpretation metadata.
///
/// Markers we keep:
///   - APP0 (JFIF) and APP14 (Adobe) — required to interpret the image.
///   - APP2 when it carries an ICC profile (unless color profile stripping is on).
///   - DQT/DHT/SOF/SOS/DRI and all coding tables and scan data.
/// Markers we drop when `stripMetadata` is set:
///   - APP1 (EXIF/XMP), APP3..APP13, APP15 and COM comments.
///   - Exception: an EXIF APP1 whose Orientation is not 1, or that marks the
///     image as Adobe RGB (1998) without an embedded ICC profile, is replaced
///     by a minimal EXIF segment carrying only those tags, so the photo is
///     still displayed the way it was shot.
enum JPEGOptimizer {
    static func optimize(_ data: [UInt8], options: OptimizationOptions) -> OptimizerOutput? {
        let stripped = stripMetadata(data, options: options)
        let base = stripped?.bytes ?? data
        var best = base
        var label = "Optimized JPEG Huffman coding"
        if options.jpegOptimizeHuffman, let candidate = JPEGRecompression.optimize(base), candidate.count < best.count {
            best = candidate
        }
        if options.jpegProgressive, let candidate = JPEGRecompression.optimize(base, progressive: true), candidate.count < best.count {
            best = candidate
            label = "Optimized progressive JPEG coding"
        }
        guard best.count < base.count else { return stripped }
        return OptimizerOutput(bytes: best, items: (stripped?.items ?? []) + [
            RemovedItem(kind: .recompression, label: label, bytes: base.count - best.count),
        ])
    }

    private static func stripMetadata(_ data: [UInt8], options: OptimizationOptions) -> OptimizerOutput? {
        guard options.stripMetadata || !options.keepColorProfile else { return nil }
        let n = data.count
        guard n >= 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(n)
        out.append(0xFF)
        out.append(0xD8)

        var items = [RemovedItem]()
        // An embedded profile takes precedence over the EXIF color space marker.
        let keepEXIFColorSpace = options.keepColorProfile && !hasICCProfile(data)

        var i = 2
        while i < n {
            guard data[i] == 0xFF else { return nil } // expected a marker

            // Skip any 0xFF fill bytes; the marker is the last 0xFF + code.
            var j = i
            while j < n, data[j] == 0xFF { j += 1 }
            guard j < n else { return nil }
            let marker = data[j]
            let markerStart = j - 1

            // Standalone markers (no length): TEM, SOI, RSTn.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0xD8 {
                out.append(0xFF)
                out.append(marker)
                i = j + 1
                continue
            }

            // End of image before any scan (unusual, but copy it and stop).
            if marker == 0xD9 {
                out.append(0xFF)
                out.append(0xD9)
                break
            }

            // Start of scan: the entropy-coded data follows and runs to the
            // end of the image. Copy everything from here verbatim — this is
            // what guarantees losslessness.
            if marker == 0xDA {
                out.append(contentsOf: data[markerStart..<n])
                break
            }

            // Length-prefixed segment.
            guard j + 2 < n else { return nil }
            let len = (Int(data[j + 1]) << 8) | Int(data[j + 2])
            guard len >= 2 else { return nil }
            let payloadStart = j + 3
            let segEnd = j + 1 + len // one past the segment
            guard segEnd <= n else { return nil }

            switch classify(marker: marker, data: data, payloadStart: payloadStart, payloadEnd: segEnd,
                            options: options, keepEXIFColorSpace: keepEXIFColorSpace) {
            case .keep:
                out.append(contentsOf: data[markerStart..<segEnd])
            case let .remove(kind, label):
                items.append(RemovedItem(kind: kind, label: label, bytes: segEnd - markerStart))
            case let .replace(segment, kind, label):
                // Only worth it when the replacement is actually smaller.
                if segment.count < segEnd - markerStart {
                    out.append(contentsOf: segment)
                    items.append(RemovedItem(kind: kind, label: label, bytes: segEnd - markerStart - segment.count))
                } else {
                    out.append(contentsOf: data[markerStart..<segEnd])
                }
            }
            i = segEnd
        }

        return OptimizerOutput(bytes: out, items: items)
    }

    private enum SegmentAction {
        case keep
        case remove(RemovalKind, String)
        /// Write `segment` (a complete marker segment) in place of the original.
        case replace([UInt8], RemovalKind, String)
    }

    /// `keepEXIFColorSpace`: the image's colors depend on the EXIF Adobe RGB
    /// marker (color profiles are kept and none is embedded).
    private static func classify(
        marker: UInt8, data: [UInt8], payloadStart: Int, payloadEnd: Int, options: OptimizationOptions,
        keepEXIFColorSpace: Bool
    ) -> SegmentAction {
        guard let info = removal(marker: marker, data: data, payloadStart: payloadStart,
                                 payloadEnd: payloadEnd, options: options) else { return .keep }
        guard info.kind == .exif else { return .remove(info.kind, info.label) }
        guard let essentials = readEXIF(data, tiffStart: payloadStart + exifSignature.count, end: payloadEnd,
                                        colorSpace: keepEXIFColorSpace) else { return .keep }
        guard !essentials.isEmpty else { return .remove(info.kind, info.label) }
        let kept = [essentials.orientation != nil ? "orientation" : nil, essentials.adobeRGB != nil ? "color space" : nil]
        return .replace(minimalEXIF(essentials), .exif,
                        "EXIF metadata (APP1), \(kept.compactMap { $0 }.joined(separator: " and ")) kept")
    }

    /// Returns nil to keep the segment, or the removal info to drop it.
    private static func removal(
        marker: UInt8, data: [UInt8], payloadStart: Int, payloadEnd: Int, options: OptimizationOptions
    ) -> (kind: RemovalKind, label: String)? {
        switch marker {
        case 0xE0, 0xEE:
            return nil // APP0 (JFIF), APP14 (Adobe color transform) — keep

        case 0xE2: // APP2 — usually ICC profile
            let icc = isICCProfile(data, from: payloadStart, to: payloadEnd)
            if icc {
                return options.keepColorProfile ? nil : (.colorProfile, "ICC color profile (APP2)")
            }
            return options.stripMetadata ? (.appData, "Application data (APP2)") : nil

        case 0xE1: // APP1 — EXIF or XMP
            guard options.stripMetadata else { return nil }
            if startsWith(data, payloadStart, payloadEnd, exifSignature) {
                return (.exif, "EXIF metadata (APP1)")
            }
            if startsWith(data, payloadStart, payloadEnd, Array("http://ns.adobe.com/xap/".utf8)) {
                return (.xmp, "XMP metadata (APP1)")
            }
            return (.appData, "Application data (APP1)")

        case 0xED: // APP13 — Photoshop / IPTC
            guard options.stripMetadata else { return nil }
            if startsWith(data, payloadStart, payloadEnd, Array("Photoshop".utf8)) {
                return (.iptc, "IPTC / Photoshop metadata (APP13)")
            }
            return (.appData, "Application data (APP13)")

        case 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xEF:
            guard options.stripMetadata else { return nil }
            let n = Int(marker - 0xE0)
            return (.appData, "Application data (APP\(n))")

        case 0xFE:
            guard options.stripMetadata else { return nil }
            return (.comment, "Comment (COM)")

        default:
            return nil // DQT, DHT, SOFn, DRI, DAC, etc.
        }
    }

    // MARK: - EXIF essentials

    /// "Exif\0\0", the APP1 identifier that precedes the TIFF structure.
    private static let exifSignature: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
    private static let orientationTag: UInt16 = 0x0112
    private static let exifIFDTag: UInt16 = 0x8769
    private static let colorSpaceTag: UInt16 = 0xA001
    private static let interopIFDTag: UInt16 = 0xA005
    private static let interopIndexTag: UInt16 = 0x0001
    private static let adobeRGBIndex: [UInt8] = Array("R03".utf8)

    /// The parts of an EXIF segment that change how the image is displayed.
    struct EXIFEssentials: Equatable {
        var bigEndian: Bool
        /// 2...8 when the image is rotated or mirrored; nil when absent, 1, or a
        /// value outside 1...8 (which viewers ignore).
        var orientation: UInt16?
        /// InteroperabilityIndex "R03": the DCF marker for Adobe RGB (1998),
        /// used by cameras that embed no ICC profile. Nil when absent.
        var adobeRGB: AdobeRGBMarker?

        var isEmpty: Bool { orientation == nil && adobeRGB == nil }
    }

    /// The "R03" index is kept with the ColorSpace value found beside it (DCF
    /// pairs it with Uncalibrated), so the pair reads exactly as before.
    struct AdobeRGBMarker: Equatable {
        /// The Exif IFD's ColorSpace, or nil when that tag is absent.
        var colorSpace: UInt16?

        /// The standard DCF pairing: ColorSpace Uncalibrated.
        static let dcf = AdobeRGBMarker(colorSpace: 0xFFFF)
    }

    private struct MalformedTIFF: Error {}

    private struct TIFFEntry {
        let tag: UInt16, type: UInt16, count: UInt32
        /// Offset of the 4-byte value field, relative to the TIFF header.
        let valueOffset: Int
    }

    /// Bounds-checked reads from the TIFF structure in `bytes[start..<start + length]`.
    private struct TIFFReader {
        let bytes: [UInt8], start: Int, length: Int, bigEndian: Bool

        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset + 2 <= length else { throw MalformedTIFF() }
            let a = UInt16(bytes[start + offset]), b = UInt16(bytes[start + offset + 1])
            return bigEndian ? (a << 8 | b) : (b << 8 | a)
        }

        func u32(_ offset: Int) throws -> UInt32 {
            let first = UInt32(try u16(offset)), second = UInt32(try u16(offset + 2))
            return bigEndian ? (first << 16 | second) : (second << 16 | first)
        }

        /// The entries of the IFD at `offset`, which must be complete, including
        /// the 4-byte next-IFD offset that follows them.
        func ifd(at offset: Int) throws -> [TIFFEntry] {
            guard offset >= 8, offset <= length - 2 else { throw MalformedTIFF() }
            let count = Int(try u16(offset))
            guard offset + 2 + count * 12 + 4 <= length else { throw MalformedTIFF() }
            return try (0..<count).map { index in
                let entry = offset + 2 + index * 12
                return TIFFEntry(tag: try u16(entry), type: try u16(entry + 2), count: try u32(entry + 4),
                                 valueOffset: entry + 8)
            }
        }

        /// The offset stored in a sub-IFD pointer entry (LONG or IFD, count 1).
        func pointer(_ entry: TIFFEntry) throws -> Int {
            guard entry.type == 4 || entry.type == 13, entry.count == 1 else { throw MalformedTIFF() }
            return Int(try u32(entry.valueOffset))
        }
    }

    /// The single entry with `tag`, nil when absent. Duplicates are ambiguous.
    private static func unique(_ tag: UInt16, in entries: [TIFFEntry]) throws -> TIFFEntry? {
        let matches = entries.filter { $0.tag == tag }
        guard matches.count <= 1 else { throw MalformedTIFF() }
        return matches.first
    }

    /// Reads the display-relevant EXIF tags from the TIFF structure in
    /// `d[tiffStart..<end]`: Orientation from IFD0 and, when `colorSpace` is
    /// set, the Adobe RGB marker from the Exif and Interoperability IFDs.
    /// Returns nil when anything it needs can't be read with confidence, so the
    /// caller keeps the original segment instead of guessing.
    static func readEXIF(_ d: [UInt8], tiffStart: Int, end: Int, colorSpace: Bool) -> EXIFEssentials? {
        try? parseEXIF(d, tiffStart: tiffStart, end: end, colorSpace: colorSpace)
    }

    private static func parseEXIF(_ d: [UInt8], tiffStart: Int, end: Int, colorSpace: Bool) throws -> EXIFEssentials {
        guard tiffStart >= 0, end <= d.count, end - tiffStart >= 8 else { throw MalformedTIFF() }
        let bigEndian: Bool
        switch (d[tiffStart], d[tiffStart + 1]) {
        case (0x4D, 0x4D): bigEndian = true   // "MM"
        case (0x49, 0x49): bigEndian = false  // "II"
        default: throw MalformedTIFF()
        }
        let tiff = TIFFReader(bytes: d, start: tiffStart, length: end - tiffStart, bigEndian: bigEndian)
        guard try tiff.u16(2) == 42 else { throw MalformedTIFF() }
        let ifd0 = try tiff.ifd(at: Int(try tiff.u32(4)))
        var essentials = EXIFEssentials(bigEndian: bigEndian, orientation: nil, adobeRGB: nil)

        if let entry = try unique(orientationTag, in: ifd0) {
            // Exactly one SHORT value, stored inline; anything else is ambiguous.
            guard entry.type == 3, entry.count == 1 else { throw MalformedTIFF() }
            let value = try tiff.u16(entry.valueOffset)
            // Values outside 2...8 do not rotate the image.
            if (2...8).contains(value) { essentials.orientation = value }
        }

        guard colorSpace, let exifPointer = try unique(exifIFDTag, in: ifd0) else { return essentials }
        let exifIFD = try tiff.ifd(at: try tiff.pointer(exifPointer))
        var space: UInt16?
        if let entry = try unique(colorSpaceTag, in: exifIFD) {
            guard entry.type == 3, entry.count == 1 else { throw MalformedTIFF() }
            space = try tiff.u16(entry.valueOffset)
        }
        guard let interopPointer = try unique(interopIFDTag, in: exifIFD) else { return essentials }
        let interop = try tiff.ifd(at: try tiff.pointer(interopPointer))
        guard let index = try unique(interopIndexTag, in: interop) else { return essentials }
        // An ASCII index such as "R03\0" fits inline in the value field.
        guard index.type == 2, (3...4).contains(index.count) else { throw MalformedTIFF() }
        let value = tiffStart + index.valueOffset
        if Array(d[value..<(value + 3)]) == adobeRGBIndex {
            essentials.adobeRGB = AdobeRGBMarker(colorSpace: space)
        }
        return essentials
    }

    /// A complete APP1 segment holding only `essentials`, in its byte order:
    /// IFD0 with Orientation and, for Adobe RGB, an Exif IFD with the original
    /// ColorSpace (if any) whose Interoperability IFD has index "R03". No
    /// next IFD.
    static func minimalEXIF(_ essentials: EXIFEssentials) -> [UInt8] {
        let bigEndian = essentials.bigEndian
        func u16(_ v: UInt16) -> [UInt8] {
            bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
        }
        func u32(_ v: UInt32) -> [UInt8] {
            bigEndian ? u16(UInt16(v >> 16)) + u16(UInt16(v & 0xFFFF))
                      : u16(UInt16(v & 0xFFFF)) + u16(UInt16(v >> 16))
        }
        func entry(_ tag: UInt16, _ type: UInt16, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(1) + value  // value: 4 bytes, left-aligned
        }
        func pointer(_ tag: UInt16, to offset: Int) -> [UInt8] { entry(tag, 4, u32(UInt32(offset))) }
        func ifd(_ entries: [[UInt8]]) -> [UInt8] {
            u16(UInt16(entries.count)) + entries.joined() + u32(0)  // no next IFD
        }
        func size(_ entryCount: Int) -> Int { 2 + entryCount * 12 + 4 }

        var ifd0 = [[UInt8]]()
        if let orientation = essentials.orientation {
            ifd0.append(entry(orientationTag, 3, u16(orientation) + u16(0)))
        }
        var tiff: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        tiff += u16(42) + u32(8)  // IFD0 at offset 8
        if let marker = essentials.adobeRGB {
            var exif = [[UInt8]]()
            if let space = marker.colorSpace { exif.append(entry(colorSpaceTag, 3, u16(space) + u16(0))) }
            let exifOffset = 8 + size(ifd0.count + 1)
            let interopOffset = exifOffset + size(exif.count + 1)
            ifd0.append(pointer(exifIFDTag, to: exifOffset))
            exif.append(pointer(interopIFDTag, to: interopOffset))
            tiff += ifd(ifd0)
            tiff += ifd(exif)
            var index = u16(interopIndexTag) + u16(2) + u32(4)
            index += adobeRGBIndex + [0]  // "R03\0", inline
            tiff += ifd([index])
        } else {
            tiff += ifd(ifd0)
        }
        let payload = exifSignature + tiff
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    /// Orientation-only convenience for ``minimalEXIF(_:)``.
    static func minimalEXIF(orientation: UInt16, bigEndian: Bool) -> [UInt8] {
        minimalEXIF(EXIFEssentials(bigEndian: bigEndian, orientation: orientation, adobeRGB: nil))
    }

    /// Whether an APP2 ICC profile appears among the header segments.
    private static func hasICCProfile(_ d: [UInt8]) -> Bool {
        var i = 2
        while i < d.count, d[i] == 0xFF {
            var j = i
            while j < d.count, d[j] == 0xFF { j += 1 }
            guard j + 2 < d.count else { return false }
            let marker = d[j]
            if marker == 0xDA || marker == 0xD9 { return false }  // scan data or end
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { i = j + 1; continue }
            let length = Int(d[j + 1]) << 8 | Int(d[j + 2])
            guard length >= 2, j + 1 + length <= d.count else { return false }
            if marker == 0xE2, isICCProfile(d, from: j + 3, to: j + 1 + length) { return true }
            i = j + 1 + length
        }
        return false
    }

    private static let iccSignature: [UInt8] = Array("ICC_PROFILE".utf8)

    private static func isICCProfile(_ d: [UInt8], from start: Int, to end: Int) -> Bool {
        guard end - start >= iccSignature.count + 1 else { return false }
        for k in 0..<iccSignature.count where d[start + k] != iccSignature[k] {
            return false
        }
        return d[start + iccSignature.count] == 0x00
    }

    private static func startsWith(_ d: [UInt8], _ start: Int, _ end: Int, _ prefix: [UInt8]) -> Bool {
        guard end - start >= prefix.count else { return false }
        for k in 0..<prefix.count where d[start + k] != prefix[k] {
            return false
        }
        return true
    }
}
