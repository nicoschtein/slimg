import CZopfli

enum Zopfli {
    static let maximumSize = 1024 * 1024

    static func compress(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty, input.count <= maximumSize else { return nil }
        var count = 0
        let pointer = input.withUnsafeBufferPointer { buffer in
            czopfli_compress(buffer.baseAddress, buffer.count, &count)
        }
        guard let pointer else { return nil }
        defer { czopfli_free(pointer) }
        let compressed = Array(UnsafeBufferPointer(start: pointer, count: count))
        // Verify the vendored encoder using the independently linked system zlib.
        guard Zlib.inflate(compressed, maximumSize: input.count) == input else { return nil }
        return compressed
    }
}
