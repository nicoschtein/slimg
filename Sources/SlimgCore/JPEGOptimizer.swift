/// Lossless JPEG optimization: drops metadata marker segments (EXIF, XMP,
/// IPTC/Photoshop, comments) without touching the entropy-coded scan data,
/// so decoded pixels are byte-for-byte identical.
///
/// Markers we keep:
///   - APP0 (JFIF) and APP14 (Adobe) — required to interpret the image.
///   - APP2 when it carries an ICC profile (unless color profile stripping is on).
///   - DQT/DHT/SOF/SOS/DRI and all coding tables and scan data.
/// Markers we drop when `stripMetadata` is set:
///   - APP1 (EXIF/XMP), APP3..APP13, APP15 and COM comments.
enum JPEGOptimizer {
    static func optimize(_ data: [UInt8], options: OptimizationOptions) -> OptimizerOutput? {
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

            if let info = classify(marker: marker, data: data, payloadStart: payloadStart, payloadEnd: segEnd, options: options) {
                items.append(RemovedItem(kind: info.kind, label: info.label, bytes: segEnd - markerStart))
            } else {
                out.append(contentsOf: data[markerStart..<segEnd])
            }
            i = segEnd
        }

        return OptimizerOutput(bytes: out, items: items)
    }

    /// Returns nil to keep the segment, or the removal info to drop it.
    private static func classify(
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
            if startsWith(data, payloadStart, payloadEnd, [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
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
