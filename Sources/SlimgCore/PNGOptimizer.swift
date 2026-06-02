/// Lossless PNG optimization:
///   1. Drops metadata chunks (tEXt, zTXt, iTXt, tIME, eXIf) and, when color
///      profile stripping is requested, iCCP.
///   2. Re-deflates the image data (IDAT) at maximum zlib compression. Because
///      the inflated filtered scanlines are unchanged, decoded pixels are
///      byte-for-byte identical.
/// All rendering-relevant chunks (IHDR, PLTE, tRNS, gAMA, cHRM, sRGB, sBIT,
/// bKGD, pHYs, …) are preserved.
enum PNGOptimizer {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private struct Chunk {
        let type: String
        let dataRange: Range<Int>  // chunk data (no length/type/crc)
        let rawRange: Range<Int>   // full chunk: length+type+data+crc
    }

    static func optimize(_ data: [UInt8], options: OptimizationOptions) -> OptimizerOutput? {
        let n = data.count
        guard n > 8, Array(data[0..<8]) == signature else { return nil }

        var chunks = [Chunk]()
        var i = 8
        while i + 8 <= n {
            let length = (Int(data[i]) << 24) | (Int(data[i + 1]) << 16)
                | (Int(data[i + 2]) << 8) | Int(data[i + 3])
            guard length >= 0 else { return nil }
            let typeStart = i + 4
            guard typeStart + 4 <= n else { return nil }
            guard let type = String(bytes: data[typeStart..<typeStart + 4], encoding: .ascii) else { return nil }
            let dataStart = typeStart + 4
            let dataEnd = dataStart + length
            let crcEnd = dataEnd + 4
            guard crcEnd <= n else { return nil }
            chunks.append(Chunk(type: type, dataRange: dataStart..<dataEnd, rawRange: i..<crcEnd))
            i = crcEnd
            if type == "IEND" { break }
        }

        guard let first = chunks.first, first.type == "IHDR" else { return nil }

        var items = [RemovedItem]()

        // Build a single re-deflated IDAT if it is smaller than the original.
        var rebuiltIDAT: [UInt8]? = nil
        let idatChunks = chunks.filter { $0.type == "IDAT" }
        let originalIDATRaw = idatChunks.reduce(0) { $0 + $1.rawRange.count }
        if options.recompress, !idatChunks.isEmpty {
            var combined = [UInt8]()
            for c in idatChunks { combined.append(contentsOf: data[c.dataRange]) }
            if let raw = Zlib.inflate(combined),
               let redeflated = Zlib.deflate(raw, level: 9),
               redeflated.count < combined.count {
                rebuiltIDAT = redeflated
            }
        }
        if let rebuiltIDAT {
            let newRaw = 12 + rebuiltIDAT.count // length(4) + type(4) + data + crc(4)
            let saved = originalIDATRaw - newRaw
            if saved > 0 {
                items.append(RemovedItem(kind: .recompression, label: "Recompressed image data (IDAT)", bytes: saved))
            }
        }

        var out = [UInt8]()
        out.reserveCapacity(n)
        out.append(contentsOf: signature)

        var emittedIDAT = false
        for c in chunks {
            if c.type == "IDAT" {
                if emittedIDAT { continue }
                emittedIDAT = true
                if let rebuiltIDAT {
                    appendChunk(&out, type: "IDAT", data: rebuiltIDAT)
                } else {
                    for idat in idatChunks { out.append(contentsOf: data[idat.rawRange]) }
                }
                continue
            }
            if let info = removalInfo(for: c, data: data, options: options) {
                items.append(RemovedItem(kind: info.kind, label: info.label, bytes: c.rawRange.count))
                continue
            }
            out.append(contentsOf: data[c.rawRange])
        }

        return OptimizerOutput(bytes: out, items: items)
    }

    /// Returns removal info if the chunk should be dropped, else nil (keep).
    private static func removalInfo(for chunk: Chunk, data: [UInt8], options: OptimizationOptions)
        -> (kind: RemovalKind, label: String)? {
        switch chunk.type {
        case "tEXt", "zTXt", "iTXt":
            guard options.stripMetadata else { return nil }
            if let keyword = textKeyword(data, chunk.dataRange) {
                return (.textMetadata, "Text: \(keyword) (\(chunk.type))")
            }
            return (.textMetadata, "Text metadata (\(chunk.type))")
        case "tIME":
            guard options.stripMetadata else { return nil }
            return (.timestamp, "Timestamp (tIME)")
        case "eXIf":
            guard options.stripMetadata else { return nil }
            return (.exif, "EXIF metadata (eXIf)")
        case "iCCP":
            guard !options.keepColorProfile else { return nil }
            return (.colorProfile, "ICC color profile (iCCP)")
        default:
            return nil
        }
    }

    /// The leading keyword of a text chunk (bytes up to the first NUL).
    private static func textKeyword(_ data: [UInt8], _ range: Range<Int>) -> String? {
        var bytes = [UInt8]()
        for idx in range {
            if data[idx] == 0 { break }
            bytes.append(data[idx])
            if bytes.count > 79 { break } // PNG keyword max length
        }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(bytes: bytes, encoding: .ascii)
    }

    private static func appendChunk(_ out: inout [UInt8], type: String, data: [UInt8]) {
        let len = data.count
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))

        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)

        var crcInput = typeBytes
        crcInput.append(contentsOf: data)
        let crc = CRC32.checksum(crcInput)
        out.append(UInt8((crc >> 24) & 0xFF))
        out.append(UInt8((crc >> 16) & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        out.append(UInt8(crc & 0xFF))
    }
}

enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
