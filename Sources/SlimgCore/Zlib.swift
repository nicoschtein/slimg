import CZlib

/// Thin Swift wrapper over the C zlib shim. Used for lossless PNG re-compression.
enum Zlib {
    /// Inflate a complete zlib stream. Returns nil on error.
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        var outLen = 0
        let ptr = data.withUnsafeBufferPointer { buf in
            czlib_inflate(buf.baseAddress, buf.count, &outLen)
        }
        guard let p = ptr else { return nil }
        defer { czlib_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }

    /// Deflate raw bytes into a complete zlib stream. Returns nil on error.
    static func deflate(_ data: [UInt8], level: Int32 = 9) -> [UInt8]? {
        var outLen = 0
        let ptr = data.withUnsafeBufferPointer { buf in
            czlib_deflate(buf.baseAddress, buf.count, level, &outLen)
        }
        guard let p = ptr else { return nil }
        defer { czlib_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }
}
