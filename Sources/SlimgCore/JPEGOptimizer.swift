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
///   - Exception: an EXIF APP1 whose Orientation is not 1 is replaced by a
///     minimal EXIF segment carrying only that Orientation, so the photo is
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

            switch classify(marker: marker, data: data, payloadStart: payloadStart, payloadEnd: segEnd, options: options) {
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

    private static func classify(
        marker: UInt8, data: [UInt8], payloadStart: Int, payloadEnd: Int, options: OptimizationOptions
    ) -> SegmentAction {
        guard let info = removal(marker: marker, data: data, payloadStart: payloadStart,
                                 payloadEnd: payloadEnd, options: options) else { return .keep }
        guard info.kind == .exif else { return .remove(info.kind, info.label) }
        switch exifOrientation(data, tiffStart: payloadStart + exifSignature.count, end: payloadEnd) {
        case .malformed:
            return .keep
        case .absentOrUpright:
            return .remove(info.kind, info.label)
        case let .rotated(value, bigEndian):
            return .replace(minimalEXIF(orientation: value, bigEndian: bigEndian),
                            .exif, "EXIF metadata (APP1), orientation kept")
        }
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

    // MARK: - EXIF orientation

    /// "Exif\0\0", the APP1 identifier that precedes the TIFF structure.
    private static let exifSignature: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
    private static let orientationTag: UInt16 = 0x0112

    private enum EXIFOrientation {
        /// The TIFF structure could not be read with confidence.
        case malformed
        /// IFD0 has no Orientation tag, or it is 1 (already upright).
        case absentOrUpright
        /// Orientation 2...8, plus whether the source TIFF is big-endian.
        case rotated(UInt16, Bool)
    }

    /// Reads the Orientation tag from IFD0 of the TIFF structure in
    /// `d[tiffStart..<end]`. Anything unexpected is reported as malformed so the
    /// caller keeps the original segment instead of guessing.
    private static func exifOrientation(_ d: [UInt8], tiffStart: Int, end: Int) -> EXIFOrientation {
        let length = end - tiffStart
        guard tiffStart >= 0, end <= d.count, length >= 8 else { return .malformed }

        let bigEndian: Bool
        switch (d[tiffStart], d[tiffStart + 1]) {
        case (0x4D, 0x4D): bigEndian = true   // "MM"
        case (0x49, 0x49): bigEndian = false  // "II"
        default: return .malformed
        }
        // Offsets are relative to tiffStart and must be bounds-checked by callers.
        func u16(_ offset: Int) -> UInt16 {
            let a = UInt16(d[tiffStart + offset]), b = UInt16(d[tiffStart + offset + 1])
            return bigEndian ? (a << 8 | b) : (b << 8 | a)
        }
        func u32(_ offset: Int) -> UInt32 {
            let first = UInt32(u16(offset)), second = UInt32(u16(offset + 2))
            return bigEndian ? (first << 16 | second) : (second << 16 | first)
        }

        guard u16(2) == 42 else { return .malformed }
        let ifd = Int(u32(4))
        guard ifd >= 8, ifd <= length - 2 else { return .malformed }
        let count = Int(u16(ifd))
        // Entries plus the 4-byte next-IFD offset must all be present.
        guard ifd + 2 + count * 12 + 4 <= length else { return .malformed }

        var orientation: UInt16?
        for index in 0..<count {
            let entry = ifd + 2 + index * 12
            guard u16(entry) == orientationTag else { continue }
            // Exactly one SHORT value, stored inline; anything else is ambiguous.
            guard orientation == nil, u16(entry + 2) == 3, u32(entry + 4) == 1 else { return .malformed }
            orientation = u16(entry + 8)
        }
        guard let orientation else { return .absentOrUpright }
        switch orientation {
        case 1: return .absentOrUpright
        case 2...8: return .rotated(orientation, bigEndian)
        default: return .malformed
        }
    }

    /// A complete APP1 segment: EXIF identifier, TIFF header in the requested
    /// byte order, and an IFD0 holding only Orientation, with no next IFD.
    static func minimalEXIF(orientation: UInt16, bigEndian: Bool) -> [UInt8] {
        func u16(_ v: UInt16) -> [UInt8] {
            bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
        }
        func u32(_ v: UInt32) -> [UInt8] {
            bigEndian ? u16(UInt16(v >> 16)) + u16(UInt16(v & 0xFFFF))
                      : u16(UInt16(v & 0xFFFF)) + u16(UInt16(v >> 16))
        }
        var tiff: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        tiff += u16(42) + u32(8)                            // header, IFD0 at offset 8
        tiff += u16(1)                                      // one entry
        tiff += u16(orientationTag) + u16(3) + u32(1)       // Orientation, SHORT, count 1
        tiff += u16(orientation) + u16(0)                   // inline value, padded
        tiff += u32(0)                                      // no next IFD
        let payload = exifSignature + tiff
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
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
