/// Independent baseline JPEG entropy-token decoder used as a test oracle.
/// Unlike libjpeg-turbo, this reader is written in Swift and only understands
/// 8-bit single-scan sequential coding.
enum JPEGTokenReader {
    private struct Table {
        var counts: [Int]
        var symbols: [UInt8]
        var decode: [Int: UInt8] = [:]

        init?(counts: [Int], symbols: [UInt8]) {
            guard counts.count == 16, counts.reduce(0, +) == symbols.count,
                  Set(symbols).count == symbols.count else { return nil }
            self.counts = counts
            self.symbols = symbols
            var code = 0
            var index = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    // JPEG reserves the all-ones code for padding.
                    guard code < (1 << length) - 1 else { return nil }
                    let symbol = symbols[index]
                    decode[(1 << length) | code] = symbol
                    code += 1
                    index += 1
                }
                code <<= 1
            }
        }
    }

    private struct Component {
        let id: UInt8
        let h: Int
        let v: Int
        var dc = 0
        var ac = 0
    }

    private struct JPEG {
        var prefix: [UInt8]
        var scanHeader: [UInt8]
        var entropy: [UInt8]
        var components: [Component]
        var tables: [Int: Table]
        var mcuCount: Int
        var restartInterval: Int
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var bits = 0
        var value = 0

        mutating func read(_ count: Int) -> Int? {
            var result = 0
            for _ in 0..<count {
                if bits == 0 {
                    guard offset < bytes.count else { return nil }
                    value = Int(bytes[offset])
                    offset += 1
                    if value == 255 {
                        guard offset < bytes.count, bytes[offset] == 0 else { return nil }
                        offset += 1
                    }
                    bits = 8
                }
                bits -= 1
                result = (result << 1) | ((value >> bits) & 1)
            }
            return result
        }

        mutating func symbol(_ table: Table) -> UInt8? {
            var code = 0
            for length in 1...16 {
                guard let bit = read(1) else { return nil }
                code = (code << 1) | bit
                if let symbol = table.decode[(1 << length) | code] { return symbol }
            }
            return nil
        }

        mutating func restart(_ number: Int) -> Bool {
            guard bits == 0 || value & ((1 << bits) - 1) == (1 << bits) - 1,
                  offset + 1 < bytes.count, bytes[offset] == 255,
                  bytes[offset + 1] == UInt8(208 + number) else { return false }
            offset += 2
            bits = 0
            value = 0
            return true
        }

        var endedCorrectly: Bool {
            offset == bytes.count && (bits == 0 || value & ((1 << bits) - 1) == (1 << bits) - 1)
        }
    }

    /// Exact entropy-token identity for tests: preserves every coefficient's
    /// category/run and amplitude, independently of the assigned Huffman code.
    static func tokens(_ bytes: [UInt8]) -> [UInt32]? {
        guard let jpeg = parse(bytes) else { return nil }
        var values = [UInt32]()
        guard traverse(jpeg, visit: { table, symbol, amplitude, length in
            values.append(UInt32(table << 24 | Int(symbol) << 16 | length << 12 | amplitude))
            return true
        }, restart: { number in values.append(0xFFFF0000 | UInt32(number)) }) else { return nil }
        return values
    }

    private static func parse(_ bytes: [UInt8]) -> JPEG? {
        guard bytes.count >= 4, bytes[0...1] == [255, 216] else { return nil }
        var prefix: [UInt8] = [255, 216]
        var cursor = 2
        var components = [Component]()
        var tables = [Int: Table]()
        var width = 0
        var height = 0
        var quantization = Set<UInt8>()
        var usedQuantization = Set<UInt8>()
        var restartInterval = 0
        while cursor < bytes.count {
            let start = cursor
            guard bytes[cursor] == 255 else { return nil }
            while cursor < bytes.count, bytes[cursor] == 255 { cursor += 1 }
            guard cursor + 2 < bytes.count else { return nil }
            let marker = bytes[cursor]
            cursor += 1
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            guard length >= 2, length <= bytes.count - cursor else { return nil }
            let end = cursor + length
            let payload = Array(bytes[(cursor + 2)..<end])
            switch marker {
            case 192: // baseline, 8-bit
                guard components.isEmpty, payload.count >= 6, payload[0] == 8 else { return nil }
                height = Int(payload[1]) << 8 | Int(payload[2])
                width = Int(payload[3]) << 8 | Int(payload[4])
                let count = Int(payload[5])
                guard width > 0, height > 0, (count == 1 || count == 3), payload.count == 6 + count * 3 else { return nil }
                for i in 0..<count {
                    let base = 6 + i * 3
                    let h = Int(payload[base + 1] >> 4)
                    let v = Int(payload[base + 1] & 15)
                    guard (1...4).contains(h), (1...4).contains(v), payload[base + 2] <= 3,
                          !components.contains(where: { $0.id == payload[base] }) else { return nil }
                    components.append(Component(id: payload[base], h: h, v: v))
                    usedQuantization.insert(payload[base + 2])
                }
                guard components.reduce(0, { $0 + $1.h * $1.v }) <= 10 else { return nil }
            case 196:
                var p = 0
                while p < payload.count {
                    guard payload.count - p >= 17 else { return nil }
                    let key = Int(payload[p])
                    guard key & 0xEC == 0 else { return nil } // DC/AC, table IDs 0...3
                    let counts = payload[(p + 1)..<(p + 17)].map(Int.init)
                    let size = counts.reduce(0, +)
                    guard size > 0, size <= 256, payload.count - p - 17 >= size else { return nil }
                    let symbols = Array(payload[(p + 17)..<(p + 17 + size)])
                    guard let table = Table(counts: counts, symbols: symbols) else { return nil }
                    tables[key] = table
                    p += 17 + size
                }
            case 219:
                var p = 0
                while p < payload.count {
                    guard payload[p] <= 3, payload.count - p >= 65 else { return nil }
                    quantization.insert(payload[p])
                    guard !payload[(p + 1)..<(p + 65)].contains(0) else { return nil }
                    p += 65
                }
            case 221:
                guard payload.count == 2 else { return nil }
                restartInterval = Int(payload[0]) << 8 | Int(payload[1])
            case 218:
                guard !components.isEmpty, usedQuantization.isSubset(of: quantization),
                      payload.count == 1 + components.count * 2 + 3,
                      Int(payload[0]) == components.count,
                      Array(payload.suffix(3)) == [0, 63, 0] else { return nil }
                var scanComponents = [Component]()
                for i in 0..<components.count {
                    let id = payload[1 + i * 2]
                    guard var component = components.first(where: { $0.id == id }),
                          !scanComponents.contains(where: { $0.id == id }) else { return nil }
                    component.dc = Int(payload[2 + i * 2] >> 4)
                    component.ac = 16 | Int(payload[2 + i * 2] & 15)
                    guard component.dc <= 3, component.ac <= 19,
                          tables[component.dc] != nil, tables[component.ac] != nil else { return nil }
                    scanComponents.append(component)
                }
                // No extra scans, trailing data or embedded images.
                guard end + 2 <= bytes.count, bytes.suffix(2) == [255, 217] else { return nil }
                let entropy = Array(bytes[end..<(bytes.count - 2)])
                var p = 0
                while p < entropy.count {
                    if entropy[p] == 255 {
                        guard p + 1 < entropy.count, entropy[p + 1] == 0 || (208...215).contains(entropy[p + 1]) else { return nil }
                        p += 1
                    }
                    p += 1
                }
                let h = components.map(\.h).max()!
                let v = components.map(\.v).max()!
                let mcuCount: Int
                if components.count == 1 {
                    scanComponents[0] = Component(id: scanComponents[0].id, h: 1, v: 1,
                                                  dc: scanComponents[0].dc, ac: scanComponents[0].ac)
                    mcuCount = ((width + 7) / 8) * ((height + 7) / 8)
                } else {
                    mcuCount = ((width + 8 * h - 1) / (8 * h)) * ((height + 8 * v - 1) / (8 * v))
                }
                guard mcuCount <= 1_000_000,
                      mcuCount * scanComponents.reduce(0, { $0 + $1.h * $1.v }) <= 1_000_000 else { return nil }
                return JPEG(prefix: prefix, scanHeader: Array(bytes[start..<end]), entropy: entropy,
                            components: scanComponents, tables: tables, mcuCount: mcuCount, restartInterval: restartInterval)
            case 224...239, 254:
                break // Preserve all interpretation and metadata markers verbatim.
            default:
                return nil
            }
            if marker != 196 { prefix.append(contentsOf: bytes[start..<end]) }
            cursor = end
        }
        return nil
    }

    private static func traverse(_ jpeg: JPEG, visit: (Int, UInt8, Int, Int) -> Bool,
                                 restart: (Int) -> Void = { _ in }) -> Bool {
        var reader = Reader(bytes: jpeg.entropy)
        var restartNumber = 0
        for mcu in 0..<jpeg.mcuCount {
            for component in jpeg.components {
                guard let dc = jpeg.tables[component.dc], let ac = jpeg.tables[component.ac] else { return false }
                for _ in 0..<(component.h * component.v) {
                    guard let category = reader.symbol(dc), category <= 11,
                          let amplitude = reader.read(Int(category)),
                          visit(component.dc, category, amplitude, Int(category)) else { return false }
                    var coefficient = 1
                    while coefficient < 64 {
                        guard let symbol = reader.symbol(ac) else { return false }
                        let length = Int(symbol & 15)
                        let run = Int(symbol >> 4)
                        if length == 0 {
                            guard symbol == 0 || symbol == 240,
                                  visit(component.ac, symbol, 0, 0) else { return false }
                            if symbol == 0 { break }
                            coefficient += 16
                            guard coefficient <= 64 else { return false }
                        } else {
                            coefficient += run
                            guard length <= 10, coefficient < 64,
                                  let amplitude = reader.read(length),
                                  visit(component.ac, symbol, amplitude, length) else { return false }
                            coefficient += 1
                        }
                    }
                }
            }
            if jpeg.restartInterval > 0, (mcu + 1) % jpeg.restartInterval == 0, mcu + 1 < jpeg.mcuCount {
                guard reader.restart(restartNumber) else { return false }
                restart(restartNumber)
                restartNumber = (restartNumber + 1) & 7
            }
        }
        return reader.endedCorrectly
    }

}
