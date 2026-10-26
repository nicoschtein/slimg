/// Exact representation changes for static, noninterlaced PNGs. This parser
/// deliberately accepts a small subset: sample-dependent metadata that would
/// need rewriting, animation and unfamiliar unsafe chunks cause a no-op.
enum PNGReduction {
    private struct Chunk {
        let type: String
        let data: [UInt8]
    }
    private struct Image {
        let width: Int
        let height: Int
        let depth: Int
        let type: Int
        let channels: Int
        let samples: [UInt16]
    }
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    // Bound allocation and CPU independently of the compressed input size.
    private static let maxPixels = 4_000_000

    static func optimize(_ bytes: [UInt8]) -> [UInt8]? {
        guard let chunks = parse(bytes), let image = decode(chunks) else { return nil }
        var best = bytes
        var candidates = [image]
        // 16-bit to 8-bit is exact only when each sample is the replicated
        // 8-bit value, including alpha and colors hidden by zero alpha.
        if image.depth == 16, !chunks.contains(where: { $0.type == "tRNS" || $0.type == "PLTE" }),
           image.samples.allSatisfy({ $0 >> 8 == $0 & 255 }) {
            candidates.append(Image(width: image.width, height: image.height,
                                    depth: 8, type: image.type, channels: image.channels,
                                    samples: image.samples.map { $0 >> 8 }))
        }
        for candidate in candidates {
            var variants = [candidate]
            if candidate.type == 4 || candidate.type == 6 {
                let maxSample = UInt16(candidate.depth == 16 ? 65535 : 255)
                if stride(from: candidate.channels - 1, to: candidate.samples.count,
                          by: candidate.channels).allSatisfy({ candidate.samples[$0] == maxSample }) {
                    var opaque = [UInt16]()
                    opaque.reserveCapacity(candidate.samples.count / candidate.channels * (candidate.channels - 1))
                    for index in candidate.samples.indices where index % candidate.channels != candidate.channels - 1 {
                        opaque.append(candidate.samples[index])
                    }
                    variants.append(Image(width: candidate.width, height: candidate.height,
                                          depth: candidate.depth, type: candidate.type == 6 ? 2 : 0,
                                          channels: candidate.channels - 1, samples: opaque))
                }
            }
            // Greyscale sample scaling is exact only when every normalized
            // value is representable at the smaller legal bit depth.
            if !chunks.contains(where: { $0.type == "tRNS" }) {
                for variant in variants where variant.type == 0 {
                    let oldMax = (1 << variant.depth) - 1
                    for depth in [1, 2, 4, 8] where depth < variant.depth {
                        let newMax = (1 << depth) - 1
                        if variant.samples.allSatisfy({ Int($0) * newMax % oldMax == 0 }) {
                            variants.append(Image(width: variant.width, height: variant.height,
                                                  depth: depth, type: 0, channels: 1,
                                                  samples: variant.samples.map { UInt16(Int($0) * newMax / oldMax) }))
                        }
                    }
                }
            }
            for variant in variants {
                // Re-encoding the original representation alone is not this
                // option's job; only genuine structural reductions are tried.
                if variant.depth != image.depth || variant.type != image.type,
                   let output = encode(variant, chunks: chunks, palette: nil, transparency: nil),
                   output.count < best.count { best = output }
                if let indexed = palette(variant, chunks: chunks),
                   let output = encode(indexed.image, chunks: chunks,
                                       palette: indexed.colors, transparency: indexed.alpha),
                   output.count < best.count { best = output }
            }
        }
        return best.count < bytes.count ? best : nil
    }

    private static func parse(_ bytes: [UInt8]) -> [Chunk]? {
        guard bytes.count >= 8, Array(bytes.prefix(8)) == signature else { return nil }
        var chunks = [Chunk]()
        var offset = 8
        var inIDAT = false
        var endedIDAT = false
        var seen = Set<String>()
        let known: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "gAMA", "cHRM", "sRGB", "pHYs", "tEXt", "zTXt", "iTXt", "tIME", "eXIf", "sPLT"]
        while offset <= bytes.count - 12 {
            let length = integer(bytes, offset)
            guard length <= bytes.count - offset - 12 else { return nil }
            let typeBytes = Array(bytes[offset + 4..<offset + 8])
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  typeBytes[2] & 32 == 0,
                  let type = String(bytes: typeBytes, encoding: .ascii),
                  CRC32.checksum(Array(bytes[offset + 4..<offset + 8 + length])) == UInt32(integer(bytes, offset + 8 + length)) else { return nil }
            // These are not safely rewritten by this representation reducer.
            guard !["acTL", "fcTL", "fdAT", "sBIT", "bKGD", "hIST", "cICP", "mDCV", "cLLI"].contains(type) else { return nil }
            if !known.contains(type), typeBytes[0] & 32 == 0 || typeBytes[3] & 32 == 0 { return nil }
            if ["IHDR", "PLTE", "tRNS", "iCCP", "gAMA", "cHRM", "sRGB", "pHYs", "IEND"].contains(type) {
                guard seen.insert(type).inserted else { return nil }
            }
            if chunks.isEmpty && type != "IHDR" { return nil }
            // If PLTE exists it must precede tRNS, even for a suggested
            // truecolor palette. Indexed transparency requires that palette.
            if type == "PLTE", seen.contains("tRNS") { return nil }
            if type == "tRNS", let header = chunks.first?.data,
               header.count == 13, header[9] == 3, !seen.contains("PLTE") { return nil }
            if type == "IDAT" {
                guard !endedIDAT else { return nil }
                inIDAT = true
            } else if inIDAT { endedIDAT = true }
            if ["PLTE", "tRNS", "iCCP", "gAMA", "cHRM", "sRGB"].contains(type), inIDAT { return nil }
            chunks.append(Chunk(type: type, data: Array(bytes[offset + 8..<offset + 8 + length])))
            offset += length + 12
            if type == "IEND" {
                guard length == 0, offset == bytes.count, inIDAT else { return nil }
                return chunks
            }
        }
        return nil
    }

    private static func decode(_ chunks: [Chunk]) -> Image? {
        guard let header = chunks.first, header.type == "IHDR", header.data.count == 13 else { return nil }
        let h = header.data
        let width = integer(h, 0), height = integer(h, 4), depth = Int(h[8]), type = Int(h[9])
        guard width > 0, height > 0, width <= maxPixels, height <= maxPixels / width,
              h[10] == 0, h[11] == 0, h[12] == 0 else { return nil }
        let channels: Int
        switch type {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        guard (type == 0 && [1, 2, 4, 8, 16].contains(depth)) ||
              (type == 3 && [1, 2, 4, 8].contains(depth)) ||
              ([2, 4, 6].contains(type) && [8, 16].contains(depth)) else { return nil }
        if let table = chunks.first(where: { $0.type == "PLTE" }) {
            guard type != 0 && type != 4, !table.data.isEmpty,
                  table.data.count % 3 == 0, table.data.count <= 768 else { return nil }
        }
        if let transparent = chunks.first(where: { $0.type == "tRNS" }) {
            guard (type == 0 && transparent.data.count == 2) ||
                  (type == 2 && transparent.data.count == 6) || type == 3 else { return nil }
            if type == 0 || type == 2 {
                let maximumSample = (1 << depth) - 1
                for offset in stride(from: 0, to: transparent.data.count, by: 2) {
                    let sample = Int(transparent.data[offset]) * 256 + Int(transparent.data[offset + 1])
                    guard sample <= maximumSample else { return nil }
                }
            }
        }
        let rowBytes = (width * channels * depth + 7) / 8
        let compressed = chunks.filter { $0.type == "IDAT" }.flatMap(\.data)
        guard let filtered = Zlib.inflate(compressed, maximumSize: height * (rowBytes + 1)), filtered.count == height * (rowBytes + 1),
              let raw = unfilter(filtered, rowBytes: rowBytes, height: height,
                                 bpp: max(1, (channels * depth + 7) / 8)) else { return nil }
        var samples = [UInt16]()
        samples.reserveCapacity(width * height * channels)
        for row in 0..<height {
            for x in 0..<width * channels {
                let base = row * rowBytes
                if depth == 16 {
                    samples.append(UInt16(raw[base + x * 2]) << 8 | UInt16(raw[base + x * 2 + 1]))
                } else if depth == 8 {
                    samples.append(UInt16(raw[base + x]))
                } else {
                    let shift = 8 - depth - ((x * depth) % 8)
                    samples.append(UInt16((raw[base + x * depth / 8] >> shift) & UInt8((1 << depth) - 1)))
                }
            }
        }
        if type == 3 {
            guard let table = chunks.first(where: { $0.type == "PLTE" })?.data,
                  !table.isEmpty, table.count % 3 == 0, table.count <= 3 * (1 << depth),
                  samples.allSatisfy({ Int($0) < table.count / 3 }),
                  (chunks.first(where: { $0.type == "tRNS" })?.data.count ?? 0) <= table.count / 3 else { return nil }
        }
        return Image(width: width, height: height, depth: depth, type: type, channels: channels, samples: samples)
    }

    private static func palette(_ image: Image, chunks: [Chunk]) -> (image: Image, colors: [UInt8], alpha: [UInt8])? {
        guard image.type == 3 || (image.depth == 8 && (image.type == 2 || image.type == 6)) else { return nil }
        let oldPalette = chunks.first(where: { $0.type == "PLTE" })?.data ?? []
        let oldAlpha = chunks.first(where: { $0.type == "tRNS" })?.data ?? []
        var colors = [UInt8](), alphas = [UInt8](), indices = [UInt16]()
        var mapping = [UInt32: UInt16]()
        for pixel in 0..<image.width * image.height {
            let base = pixel * image.channels
            let r: UInt8, g: UInt8, b: UInt8, a: UInt8
            if image.type == 3 {
                let index = Int(image.samples[base])
                r = oldPalette[index * 3]; g = oldPalette[index * 3 + 1]; b = oldPalette[index * 3 + 2]
                a = index < oldAlpha.count ? oldAlpha[index] : 255
            } else {
                r = UInt8(image.samples[base]); g = UInt8(image.samples[base + 1]); b = UInt8(image.samples[base + 2])
                if image.type == 6 { a = UInt8(image.samples[base + 3]) }
                else if oldAlpha.count == 6 {
                    let matches = UInt16(r) == UInt16(oldAlpha[0]) << 8 | UInt16(oldAlpha[1]) &&
                        UInt16(g) == UInt16(oldAlpha[2]) << 8 | UInt16(oldAlpha[3]) &&
                        UInt16(b) == UInt16(oldAlpha[4]) << 8 | UInt16(oldAlpha[5])
                    a = matches ? 0 : 255
                } else { a = 255 }
            }
            let key = UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
            if let index = mapping[key] { indices.append(index) }
            else {
                guard mapping.count < 256 else { return nil }
                let index = UInt16(mapping.count)
                mapping[key] = index; indices.append(index)
                colors.append(contentsOf: [r, g, b]); alphas.append(a)
            }
        }
        while alphas.last == 255 { alphas.removeLast() }
        let count = mapping.count
        let depth = count <= 2 ? 1 : count <= 4 ? 2 : count <= 16 ? 4 : 8
        return (Image(width: image.width, height: image.height, depth: depth,
                      type: 3, channels: 1, samples: indices), colors, alphas)
    }

    private static func encode(_ image: Image, chunks: [Chunk], palette: [UInt8]?, transparency: [UInt8]?) -> [UInt8]? {
        let rowBytes = (image.width * image.channels * image.depth + 7) / 8
        var raw = [UInt8](repeating: 0, count: rowBytes * image.height)
        for row in 0..<image.height {
            for x in 0..<image.width * image.channels {
                let sample = image.samples[(row * image.width * image.channels) + x]
                let base = row * rowBytes
                if image.depth == 16 { raw[base + x * 2] = UInt8(sample >> 8); raw[base + x * 2 + 1] = UInt8(sample & 255) }
                else if image.depth == 8 { raw[base + x] = UInt8(sample) }
                else { raw[base + x * image.depth / 8] |= UInt8(sample) << (8 - image.depth - x * image.depth % 8) }
            }
        }
        var bestCompressed: [UInt8]?
        for adaptive in [false, true] {
            let filtered = filter(raw, rowBytes: rowBytes, height: image.height,
                                  bpp: max(1, (image.channels * image.depth + 7) / 8), adaptive: adaptive)
            if let compressed = Zlib.deflate(filtered), compressed.count < (bestCompressed?.count ?? Int.max) { bestCompressed = compressed }
        }
        guard let compressed = bestCompressed else { return nil }
        var header = chunks[0].data
        header[8] = UInt8(image.depth); header[9] = UInt8(image.type)
        var output = signature
        var emitted = false
        for chunk in chunks {
            if chunk.type == "IHDR" { appendChunk(&output, type: "IHDR", data: header) }
            else if chunk.type == "PLTE" || chunk.type == "tRNS" {
                // Palette conversions replace these chunks. Other supported
                // reductions cannot affect a transparency key (16->8 skips it).
                if palette == nil { appendChunk(&output, type: chunk.type, data: chunk.data) }
            } else if chunk.type == "IDAT" {
                if emitted { continue }; emitted = true
                if let palette { appendChunk(&output, type: "PLTE", data: palette) }
                if let transparency, !transparency.isEmpty { appendChunk(&output, type: "tRNS", data: transparency) }
                appendChunk(&output, type: "IDAT", data: compressed)
            } else { appendChunk(&output, type: chunk.type, data: chunk.data) }
        }
        return output
    }

    private static func unfilter(_ filtered: [UInt8], rowBytes: Int, height: Int, bpp: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            let code = filtered[row * (rowBytes + 1)]
            guard code <= 4 else { return nil }
            for x in 0..<rowBytes {
                let index = row * rowBytes + x
                let a = x >= bpp ? output[index - bpp] : 0
                let b = row > 0 ? output[index - rowBytes] : 0
                let c = row > 0 && x >= bpp ? output[index - rowBytes - bpp] : 0
                output[index] = filtered[row * (rowBytes + 1) + x + 1] &+ predictor(code, a, b, c)
            }
        }
        return output
    }

    private static func filter(_ raw: [UInt8], rowBytes: Int, height: Int, bpp: Int, adaptive: Bool) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity((rowBytes + 1) * height)
        for row in 0..<height {
            var best = [UInt8](), bestCost = Int.max, bestCode: UInt8 = 0
            for code: UInt8 in adaptive ? [0, 1, 2, 3, 4] : [0] {
                var bytes = [UInt8](); bytes.reserveCapacity(rowBytes)
                var cost = 0
                for x in 0..<rowBytes {
                    let index = row * rowBytes + x
                    let a = x >= bpp ? raw[index - bpp] : 0
                    let b = row > 0 ? raw[index - rowBytes] : 0
                    let c = row > 0 && x >= bpp ? raw[index - rowBytes - bpp] : 0
                    let byte = raw[index] &- predictor(code, a, b, c)
                    bytes.append(byte); cost += abs(Int(Int8(bitPattern: byte)))
                }
                if cost < bestCost { best = bytes; bestCost = cost; bestCode = code }
            }
            output.append(bestCode); output.append(contentsOf: best)
        }
        return output
    }

    private static func predictor(_ code: UInt8, _ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        switch code {
        case 1: return a
        case 2: return b
        case 3: return UInt8((Int(a) + Int(b)) / 2)
        case 4:
            let p = Int(a) + Int(b) - Int(c)
            let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
            return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
        default: return 0
        }
    }

    private static func integer(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
    }
    private static func appendChunk(_ bytes: inout [UInt8], type: String, data: [UInt8]) {
        let length = data.count
        bytes.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        let body = Array(type.utf8) + data
        bytes.append(contentsOf: body)
        let crc = CRC32.checksum(body)
        bytes.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)])
    }
}
