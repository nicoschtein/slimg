/// GIF's reversible index-stream codec. Neither palettes nor frame layout are
/// changed. Keeping the index sequence also preserves colors hidden by alpha.
enum GIFLZW {
    static let maximumPixels = 32 * 1024 * 1024

    static func decode(_ bytes: [UInt8], minimumCodeSize: Int, expectedCount: Int) -> [UInt8]? {
        guard (2...8).contains(minimumCodeSize), expectedCount > 0,
              expectedCount <= maximumPixels else { return nil }
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        var prefixes = [Int](repeating: -1, count: 4096)
        var suffixes = [UInt8](repeating: 0, count: 4096)
        for i in 0..<clear { suffixes[i] = UInt8(i) }
        var next = end + 1
        var width = minimumCodeSize + 1
        var previous: Int? = nil
        var bitPosition = 0
        var result = [UInt8]()
        result.reserveCapacity(expectedCount)
        var sawClear = false

        func sequence(_ code: Int) -> [UInt8]? {
            var code = code
            var stack = [UInt8]()
            while code >= clear {
                guard code > end, code < next, prefixes[code] >= 0,
                      stack.count < 4096 else { return nil }
                stack.append(suffixes[code])
                code = prefixes[code]
            }
            stack.append(UInt8(code))
            return Array(stack.reversed())
        }

        while bitPosition / 8 < bytes.count {
            let start = bitPosition / 8
            let offset = bitPosition % 8
            guard bytes.count - start >= (offset + width + 7) / 8 else { return nil }
            var value = 0
            for b in 0..<width {
                let position = bitPosition + b
                value |= Int((bytes[position / 8] >> (position % 8)) & 1) << b
            }
            bitPosition += width
            if value == clear {
                next = end + 1
                width = minimumCodeSize + 1
                previous = nil
                sawClear = true
                continue
            }
            guard sawClear else { return nil }
            if value == end { return result.count == expectedCount ? result : nil }

            let decoded: [UInt8]
            if value < next, let entry = sequence(value) {
                decoded = entry
            } else if value == next, let previous, let entry = sequence(previous), let first = entry.first {
                decoded = entry + [first]
            } else {
                return nil
            }
            guard decoded.count <= expectedCount - result.count, let first = decoded.first else { return nil }
            result.append(contentsOf: decoded)
            if let previous, next < 4096 {
                prefixes[next] = previous
                suffixes[next] = first
                next += 1
                if next == 1 << width, width < 12 { width += 1 }
            }
            previous = value
        }
        return nil // A complete stream needs its end-of-information code.
    }

    static func encode(_ indices: [UInt8], minimumCodeSize: Int) -> [UInt8]? {
        guard (2...8).contains(minimumCodeSize), !indices.isEmpty,
              indices.count <= maximumPixels else { return nil }
        let clear = 1 << minimumCodeSize
        guard indices.allSatisfy({ Int($0) < clear }) else { return nil }
        let end = clear + 1
        var dictionary = [Int: Int]()
        dictionary.reserveCapacity(4096)
        var next = end + 1
        var bytes = [UInt8]()
        var pending: UInt32 = 0
        var pendingBits = 0

        // Track the receiving decoder's table separately: the encoder learns
        // each new entry one code earlier than the decoder does.
        var width = minimumCodeSize + 1
        var decoderNext = end + 1
        var decoderHasPrevious = false
        func emit(_ code: Int) {
            pending |= UInt32(code) << pendingBits
            pendingBits += width
            while pendingBits >= 8 {
                bytes.append(UInt8(pending & 255))
                pending >>= 8
                pendingBits -= 8
            }
            if code == clear {
                width = minimumCodeSize + 1
                decoderNext = end + 1
                decoderHasPrevious = false
            } else if code != end {
                if decoderHasPrevious, decoderNext < 4096 {
                    decoderNext += 1
                    if decoderNext == 1 << width, width < 12 { width += 1 }
                }
                decoderHasPrevious = true
            }
        }

        emit(clear)
        var prefix = Int(indices[0])
        for byte in indices.dropFirst() {
            let key = (prefix << 8) | Int(byte)
            if let code = dictionary[key] {
                prefix = code
            } else {
                emit(prefix)
                if next < 4096 {
                    dictionary[key] = next
                    next += 1
                } else {
                    emit(clear)
                    dictionary.removeAll(keepingCapacity: true)
                    next = end + 1
                }
                prefix = Int(byte)
            }
        }
        emit(prefix)
        emit(end)
        if pendingBits > 0 { bytes.append(UInt8(pending & 255)) }
        return bytes
    }

    static func subBlocks(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        for start in stride(from: 0, to: bytes.count, by: 255) {
            let end = min(start + 255, bytes.count)
            result.append(UInt8(end - start))
            result.append(contentsOf: bytes[start..<end])
        }
        result.append(0)
        return result
    }
}
