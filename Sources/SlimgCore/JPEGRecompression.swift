import CJPEG

/// Uses libjpeg-turbo's coefficient API. Pixels never pass through an encoder;
/// each candidate is checked against the original quantized DCT coefficients.
enum JPEGRecompression {
    static func optimize(_ bytes: [UInt8], progressive: Bool = false) -> [UInt8]? {
        var length = 0
        let pointer = bytes.withUnsafeBufferPointer {
            slimg_jpeg_optimize($0.baseAddress, $0.count, progressive ? 1 : 0, &length)
        }
        guard let pointer else { return nil }
        defer { slimg_jpeg_free(pointer) }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    static func equalCoefficients(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                slimg_jpeg_equal_coefficients(left.baseAddress, left.count, right.baseAddress, right.count) != 0
            }
        }
    }
}
