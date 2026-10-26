import CZlib

/// Thin Swift wrapper over the C zlib shim. Used for lossless PNG re-compression.
enum Zlib {
    /// Inflate a complete zlib stream. Returns nil on error.
    static func inflate(_ data: [UInt8], maximumSize: Int = 512 * 1024 * 1024) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        guard maximumSize > 0 else { return nil }
        var outLen = 0
        let ptr = data.withUnsafeBufferPointer { buf in
            czlib_inflate_bounded(buf.baseAddress, buf.count, maximumSize, &outLen)
        }
        guard let p = ptr else { return nil }
        defer { czlib_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }

    /// Deflate raw bytes into a complete zlib stream. Returns nil on error.
    static func deflate(_ data: [UInt8], level: Int32 = 9, strategy: Int32 = 0) -> [UInt8]? {
        var outLen = 0
        let ptr = data.withUnsafeBufferPointer { buf in
            czlib_deflate_strategy(buf.baseAddress, buf.count, level, strategy, &outLen)
        }
        guard let p = ptr else { return nil }
        defer { czlib_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }
}
