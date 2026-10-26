import Foundation

/// PNG filters operate on bytes, including both bytes of 16-bit samples and
/// packed sub-byte pixels. No color conversion or alpha premultiplication.
enum PNGFiltering {
    static let maximumSize = 64 * 1024 * 1024

    struct Layout {
        let rowBytes: Int
        let height: Int
        let bytesPerPixel: Int
        var filteredSize: Int { (rowBytes + 1) * height }

        init?(_ header: [UInt8]) {
            guard header.count == 13, header[10] == 0, header[11] == 0, header[12] == 0 else { return nil }
            let width = header[0..<4].reduce(0) { ($0 << 8) | Int($1) }
            let height = header[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            let depth = Int(header[8])
            let channels: Int
            switch header[9] {
            case 0: guard [1, 2, 4, 8, 16].contains(depth) else { return nil }; channels = 1
            case 2: guard [8, 16].contains(depth) else { return nil }; channels = 3
            case 3: guard [1, 2, 4, 8].contains(depth) else { return nil }; channels = 1
            case 4: guard [8, 16].contains(depth) else { return nil }; channels = 2
            case 6: guard [8, 16].contains(depth) else { return nil }; channels = 4
            default: return nil
            }
            guard width > 0, width <= 0x7FFF_FFFF, height > 0, height <= 0x7FFF_FFFF else { return nil }
            let rowBytes = (width * channels * depth + 7) / 8
            guard rowBytes < maximumSize, height <= maximumSize / (rowBytes + 1) else { return nil }
            self.rowBytes = rowBytes
            self.height = height
            self.bytesPerPixel = max(1, (channels * depth + 7) / 8)
        }
    }

    static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
    }

    static func unfilter(_ input: [UInt8], layout: Layout) -> [UInt8]? {
        guard input.count == layout.filteredSize else { return nil }
        var rows = [UInt8](repeating: 0, count: layout.rowBytes * layout.height)
        for y in 0..<layout.height {
            let source = y * (layout.rowBytes + 1)
            let type = input[source]
            guard type <= 4 else { return nil }
            let row = y * layout.rowBytes
            for x in 0..<layout.rowBytes {
                let a = x >= layout.bytesPerPixel ? Int(rows[row + x - layout.bytesPerPixel]) : 0
                let b = y > 0 ? Int(rows[row + x - layout.rowBytes]) : 0
                let c = y > 0 && x >= layout.bytesPerPixel ? Int(rows[row + x - layout.rowBytes - layout.bytesPerPixel]) : 0
                let predictor: Int
                switch type {
                case 1: predictor = a
                case 2: predictor = b
                case 3: predictor = (a + b) / 2
                case 4: predictor = paeth(a, b, c)
                default: predictor = 0
                }
                rows[row + x] = input[source + 1 + x] &+ UInt8(predictor)
            }
        }
        return rows
    }

    /// A nil type chooses the smallest signed-byte magnitude sum per scanline.
    static func filter(_ rows: [UInt8], layout: Layout, type: UInt8?) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(layout.filteredSize)
        for y in 0..<layout.height {
            let row = y * layout.rowBytes
            var best = [UInt8]()
            var bestScore = Int.max
            var bestType: UInt8 = 0
            for filterType in type.map({ [$0] }) ?? [0, 1, 2, 3, 4] {
                var candidate = [UInt8](repeating: 0, count: layout.rowBytes)
                var score = 0
                for x in 0..<layout.rowBytes {
                    let a = x >= layout.bytesPerPixel ? Int(rows[row + x - layout.bytesPerPixel]) : 0
                    let b = y > 0 ? Int(rows[row + x - layout.rowBytes]) : 0
                    let c = y > 0 && x >= layout.bytesPerPixel ? Int(rows[row + x - layout.rowBytes - layout.bytesPerPixel]) : 0
                    let predictor: Int
                    switch filterType {
                    case 1: predictor = a
                    case 2: predictor = b
                    case 3: predictor = (a + b) / 2
                    case 4: predictor = paeth(a, b, c)
                    default: predictor = 0
                    }
                    let value = rows[row + x] &- UInt8(predictor)
                    candidate[x] = value
                    score += abs(Int(Int8(bitPattern: value)))
                }
                if score < bestScore {
                    best = candidate; bestScore = score; bestType = filterType
                }
            }
            result.append(bestType)
            result.append(contentsOf: best)
        }
        return result
    }

    /// Bound both memory and search time. A budget expiry keeps the best result
    /// already found; original compressed data remains a candidate throughout.
    static func compress(_ original: [UInt8], header: [UInt8]) -> [UInt8]? {
        guard let layout = Layout(header),
              let filtered = Zlib.inflate(original, maximumSize: layout.filteredSize),
              let rows = unfilter(filtered, layout: layout) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var best = original
        let types: [UInt8?] = [nil, 0, 1, 2, 3, 4]
        // Try every strategy against original filters as well as new filters.
        for candidateIndex in 0...types.count {
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            let candidate = candidateIndex == 0 ? filtered : filter(rows, layout: layout, type: types[candidateIndex - 1])
            for strategy: Int32 in [0, 1, 3, 2, 4] {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                if let compressed = Zlib.deflate(candidate, strategy: strategy), compressed.count < best.count {
                    best = compressed
                }
            }
        }
        return best.count < original.count ? best : nil
    }
}
