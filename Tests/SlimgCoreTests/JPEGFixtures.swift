import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Shared JPEG fixtures and ImageIO checks for the EXIF preservation tests.
protocol JPEGFixtures {}

extension JPEGFixtures {
    /// A small image with saturated colors, so color-space changes show up.
    func makeCGImage(width: Int = 48, height: Int = 32) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.80, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.20, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))
        context.setFillColor(CGColor(red: 0.10, green: 0.85, blue: 0.30, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 2, y: height / 4, width: width / 3, height: height / 2))
        return context.makeImage()!
    }

    func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 255)] + payload
    }

    func app1(_ payload: [UInt8]) -> [UInt8] { segment(0xE1, payload) }

    func comment(_ text: String) -> [UInt8] { segment(0xFE, Array(text.utf8)) }

    /// Inserts segments after SOI and a leading APP0 (JFIF), where EXIF lives.
    func inserting(_ segments: [UInt8], into jpeg: [UInt8]) -> [UInt8] {
        var index = 2
        if jpeg.count > 6, jpeg[2] == 0xFF, jpeg[3] == 0xE0 {
            index = 4 + (Int(jpeg[4]) << 8 | Int(jpeg[5]))
        }
        var result = jpeg
        result.insert(contentsOf: segments, at: index)
        return result
    }

    func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start..<(start + needle.count) }
        }
        return nil
    }

    func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func orientation(_ data: Data) throws -> Int? {
        try properties(data)[kCGImagePropertyOrientation] as? Int
    }

    func decodedImage(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Decoded RGBA pixels (stored orientation, not display orientation), drawn
    /// into `space`; drawing into a fixed space applies the image's color space.
    func pixels(_ data: Data, in space: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> [UInt8] {
        let image = try decodedImage(data)
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
}
