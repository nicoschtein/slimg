/// Lossless PNG optimization:
///   1. Drops metadata chunks (tEXt, zTXt, iTXt, tIME, eXIf) and, when color
///      profile stripping is requested, iCCP.
///   2. Re-deflates the image data (IDAT) at maximum zlib compression. Because
///      the inflated filtered scanlines are unchanged, decoded pixels are
///      byte-for-byte identical.
/// Optional passes search filters/strategies, consolidate IDAT, recompress ICC
/// profiles, reduce exact sample representations and run bounded Zopfli.
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
        var ended = false
        while i + 12 <= n {
            let length = (Int(data[i]) << 24) | (Int(data[i + 1]) << 16)
                | (Int(data[i + 2]) << 8) | Int(data[i + 3])
            guard length >= 0, length <= 0x7FFF_FFFF else { return nil }
            let typeStart = i + 4
            guard typeStart + 4 <= n else { return nil }
            guard let type = String(bytes: data[typeStart..<typeStart + 4], encoding: .ascii) else { return nil }
            guard data[typeStart..<typeStart + 4].allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
            guard data[typeStart + 2] & 0x20 == 0 else { return nil }
            let dataStart = typeStart + 4
            let dataEnd = dataStart + length
            let crcEnd = dataEnd + 4
            guard crcEnd <= n else { return nil }
            let expectedCRC = data[dataEnd..<crcEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard CRC32.checksum(Array(data[typeStart..<dataEnd])) == expectedCRC else { return nil }
            chunks.append(Chunk(type: type, dataRange: dataStart..<dataEnd, rawRange: i..<crcEnd))
            i = crcEnd
            if type == "IEND" { ended = true; break }
        }

        guard ended, i == n, let first = chunks.first, first.type == "IHDR", first.dataRange.count == 13,
              chunks.filter({ $0.type == "IHDR" }).count == 1,
              chunks.last?.dataRange.isEmpty == true else { return nil }
        let knownCritical: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND"]
        guard !chunks.contains(where: { $0.type.utf8.first! & 0x20 == 0 && !knownCritical.contains($0.type) }) else { return nil }
        let idatPositions = chunks.indices.filter { chunks[$0].type == "IDAT" }
        guard let firstIDAT = idatPositions.first, let lastIDAT = idatPositions.last,
              lastIDAT - firstIDAT + 1 == idatPositions.count else { return nil }
        let header = Array(data[first.dataRange])
        guard validHeader(header) else { return nil }
        let palettes = chunks.indices.filter { chunks[$0].type == "PLTE" }
        guard palettes.count <= 1 else { return nil }
        if let palette = palettes.first {
            let count = chunks[palette].dataRange.count
            guard palette < firstIDAT, count > 0, count <= 768, count % 3 == 0,
                  header[9] != 0, header[9] != 4 else { return nil }
            if header[9] == 3, count / 3 > 1 << Int(header[8]) { return nil }
        } else if header[9] == 3 { return nil }

        // Advanced rewrites cannot safely retain unknown chunks that depend on
        // critical chunks. APNG has frame relationships requiring its own path.
        let knownChunks: Set<String> = knownCritical.union([
            "tEXt", "zTXt", "iTXt", "tIME", "eXIf", "iCCP", "gAMA", "cHRM", "sRGB", "sBIT",
            "bKGD", "pHYs", "tRNS", "sPLT", "hIST", "cICP", "mDCV", "cLLI",
        ])
        let advancedSafe = !chunks.contains { chunk in
            ["acTL", "fcTL", "fdAT", "dSIG"].contains(chunk.type)
                || (!knownChunks.contains(chunk.type) && chunk.type.utf8.last! & 0x20 == 0)
        }
        let deepCompression = options.pngDeepCompression && advancedSafe
        var structure = options.pngOptimizeStructure && advancedSafe
        let recompress = options.recompress && advancedSafe
        // If representation reduction is requested, defer Zopfli until after it
        // so a smaller exact palette/bit depth can fit within the CPU limit.
        let zopfli = options.pngZopfli && !options.pngReduceRepresentation && advancedSafe

        var items = [RemovedItem]()

        // Build a single re-deflated IDAT if it is smaller than the original.
        var rebuiltIDAT: [UInt8]? = nil
        var usedZopfli = false
        let idatChunks = chunks.filter { $0.type == "IDAT" }
        let originalIDATRaw = idatChunks.reduce(0) { $0 + $1.rawRange.count }
        if recompress || deepCompression || structure || zopfli {
            var combined = [UInt8]()
            for c in idatChunks { combined.append(contentsOf: data[c.dataRange]) }
            if structure {
                if let layout = PNGFiltering.Layout(header),
                   let filtered = Zlib.inflate(combined, maximumSize: layout.filteredSize),
                   PNGFiltering.unfilter(filtered, layout: layout) != nil {
                    // Structure rewrites are currently limited to validated,
                    // static noninterlaced PNGs within the deep-search limit.
                } else { structure = false }
            }
            if recompress, let raw = Zlib.inflate(combined),
               let redeflated = Zlib.deflate(raw, level: 9),
               redeflated.count < combined.count {
                rebuiltIDAT = redeflated
            }
            if deepCompression, let compressed = PNGFiltering.compress(combined, header: header),
               compressed.count < (rebuiltIDAT?.count ?? combined.count) {
                rebuiltIDAT = compressed
            }
            if zopfli, let layout = PNGFiltering.Layout(header), layout.filteredSize <= Zopfli.maximumSize,
               let filtered = Zlib.inflate(rebuiltIDAT ?? combined, maximumSize: layout.filteredSize),
               PNGFiltering.unfilter(filtered, layout: layout) != nil,
               let compressed = Zopfli.compress(filtered), compressed.count < (rebuiltIDAT?.count ?? combined.count) {
                rebuiltIDAT = compressed
                usedZopfli = true
            }
            if structure, idatChunks.count > 1, rebuiltIDAT == nil { rebuiltIDAT = combined }
        }
        if let rebuiltIDAT {
            let newRaw = 12 + rebuiltIDAT.count // length(4) + type(4) + data + crc(4)
            let saved = originalIDATRaw - newRaw
            if saved > 0 {
                let label: String
                if usedZopfli {
                    label = "Zopfli-compressed image data (IDAT)"
                } else if deepCompression {
                    label = "Deep-compressed image data (IDAT)"
                } else if structure && rebuiltIDAT.count == idatChunks.reduce(0, { $0 + $1.dataRange.count }) {
                    label = "Consolidated image chunks (IDAT)"
                } else {
                    label = "Recompressed image data (IDAT)"
                }
                items.append(RemovedItem(kind: .recompression, label: label, bytes: saved))
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
            if structure, c.type == "iCCP", let compressed = recompressProfile(Array(data[c.dataRange])),
               compressed.count < c.dataRange.count {
                appendChunk(&out, type: c.type, data: compressed)
                items.append(RemovedItem(kind: .recompression, label: "Recompressed ICC profile (iCCP)", bytes: c.dataRange.count - compressed.count))
                continue
            }
            out.append(contentsOf: data[c.rawRange])
        }

        if options.pngReduceRepresentation, advancedSafe, let reduced = PNGReduction.optimize(out), reduced.count < out.count {
            items.append(RemovedItem(kind: .recompression, label: "Reduced PNG representation losslessly", bytes: out.count - reduced.count))
            out = reduced
        }
        if options.pngZopfli && options.pngReduceRepresentation {
            var finalOptions = OptimizationOptions(stripMetadata: false, recompress: false)
            finalOptions.pngZopfli = true
            if let compressed = optimize(out, options: finalOptions), compressed.bytes.count < out.count {
                items.append(contentsOf: compressed.items)
                out = compressed.bytes
            }
        }
        return OptimizerOutput(bytes: out, items: items)
    }

    private static func validHeader(_ header: [UInt8]) -> Bool {
        guard header.count == 13, header[10] == 0, header[11] == 0, header[12] <= 1 else { return false }
        for start in [0, 4] {
            let dimension = header[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard dimension > 0, dimension <= 0x7FFF_FFFF else { return false }
        }
        switch header[9] {
        case 0: return [1, 2, 4, 8, 16].contains(header[8])
        case 2, 4, 6: return [8, 16].contains(header[8])
        case 3: return [1, 2, 4, 8].contains(header[8])
        default: return false
        }
    }

    private static func recompressProfile(_ data: [UInt8]) -> [UInt8]? {
        guard let nul = data.firstIndex(of: 0), (1...79).contains(nul), nul + 2 < data.count,
              data[nul + 1] == 0,
              let profile = Zlib.inflate(Array(data[(nul + 2)...]), maximumSize: 16 * 1024 * 1024),
              let compressed = Zlib.deflate(profile) else { return nil }
        return Array(data[...(nul + 1)]) + compressed
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
