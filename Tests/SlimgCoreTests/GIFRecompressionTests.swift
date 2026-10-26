import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

final class GIFRecompressionTests: XCTestCase {
    /// An independent, deliberately inefficient GIF encoder: clear before
    /// every literal, so every code has the initial fixed width.
    private func literalStream(_ pixels: [UInt8], minimum: Int) -> [UInt8] {
        let clear = 1 << minimum
        let width = minimum + 1
        var pending: UInt32 = 0
        var bits = 0
        var result = [UInt8]()
        func emit(_ value: Int) {
            pending |= UInt32(value) << bits
            bits += width
            while bits >= 8 {
                result.append(UInt8(pending & 255))
                pending >>= 8
                bits -= 8
            }
        }
        for pixel in pixels { emit(clear); emit(Int(pixel)) }
        emit(clear + 1)
        if bits > 0 { result.append(UInt8(pending & 255)) }
        return result
    }

    private func makeGIF(frames: [[UInt8]], width: Int, height: Int,
                         minimum: Int = 2, interlaced: Bool = false,
                         localPalette: Bool = false, compressed: [[UInt8]]? = nil) -> Data {
        func word(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
        var out = Array("GIF89a".utf8) + word(width) + word(height)
        out += [0x80 | UInt8(minimum - 1), 0, 0]
        var palette = [UInt8]()
        for i in 0..<(1 << minimum) {
            palette.append(UInt8(i))
            palette.append(UInt8(255 - i))
            palette.append(UInt8((i * 17) & 255))
        }
        out += palette
        out += [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 5, 0, 0]
        out += [0x21, 0xFE, 4] + Array("test".utf8) + [0]
        for (i, frame) in frames.enumerated() {
            let delay = i == 0 ? 7 : 13
            let disposal = i == 0 ? 2 : 3
            out += [0x21, 0xF9, 4, UInt8(disposal << 2) | 1] + word(delay) + [0, 0]
            out += [0x2C, 0, 0, 0, 0] + word(width) + word(height)
            out.append((interlaced ? 0x40 : 0) | (localPalette ? 0x80 | UInt8(minimum - 1) : 0))
            if localPalette { out += palette.reversed() }
            out.append(UInt8(minimum))
            out += GIFLZW.subBlocks(compressed?[i] ?? literalStream(frame, minimum: minimum))
        }
        out.append(0x3B)
        return Data(out)
    }

    private func assertImageIOIdentity(_ before: Data, _ after: Data, file: StaticString = #filePath,
                                       line: UInt = #line) throws {
        let a = try XCTUnwrap(CGImageSourceCreateWithData(before as CFData, nil), file: file, line: line)
        let b = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(a), CGImageSourceGetCount(b), file: file, line: line)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        for i in 0..<CGImageSourceGetCount(a) {
            let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(a, i, options), file: file, line: line)
            let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(b, i, options), file: file, line: line)
            XCTAssertEqual(first.width, second.width, file: file, line: line)
            XCTAssertEqual(first.height, second.height, file: file, line: line)
            XCTAssertEqual(first.bitsPerPixel, second.bitsPerPixel, file: file, line: line)
            XCTAssertEqual(first.dataProvider?.data as Data?, second.dataProvider?.data as Data?, file: file, line: line)
            let ap = CGImageSourceCopyPropertiesAtIndex(a, i, nil) as? [CFString: Any]
            let bp = CGImageSourceCopyPropertiesAtIndex(b, i, nil) as? [CFString: Any]
            XCTAssertEqual(ap?[kCGImagePropertyGIFDictionary] as? NSDictionary,
                           bp?[kCGImagePropertyGIFDictionary] as? NSDictionary, file: file, line: line)
        }
        let ap = CGImageSourceCopyProperties(a, nil) as? [CFString: Any]
        let bp = CGImageSourceCopyProperties(b, nil) as? [CFString: Any]
        XCTAssertEqual(ap?[kCGImagePropertyGIFDictionary] as? NSDictionary,
                       bp?[kCGImagePropertyGIFDictionary] as? NSDictionary, file: file, line: line)
    }

    func testDefaultOffAndRealSavingsWithMetadataRetained() throws {
        let pixels = (0..<(96 * 64)).map { UInt8(($0 / 96) % 4) }
        let input = makeGIF(frames: [pixels], width: 96, height: 64)
        XCTAssertFalse(OptimizationOptions().gifRecompress)
        let base = Slimg.optimize(input, options: .init(stripMetadata: false))
        XCTAssertEqual(base.data, input)
        let result = Slimg.optimize(input, options: .init(stripMetadata: false, gifRecompress: true))
        XCTAssertLessThan(result.optimizedSize, base.optimizedSize / 2)
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertTrue(result.report.items.allSatisfy { $0.kind == .recompression })
        try assertImageIOIdentity(input, result.data)
        XCTAssertEqual(Slimg.optimize(result.data, options: .init(stripMetadata: false, gifRecompress: true)).data,
                       result.data)
        print("GIF LZW fixture: \(input.count) -> \(result.optimizedSize) bytes")
    }

    func testAnimationInterlacingPalettesTransparencyAndTimingSurvive() throws {
        let a = (0..<2048).map { UInt8(($0 / 32) % 4) }
        let b = a.map { ($0 + 1) % 4 }
        for local in [false, true] {
            for interlaced in [false, true] {
                let input = makeGIF(frames: [a, b], width: 32, height: 64,
                                    interlaced: interlaced, localPalette: local)
                let result = Slimg.optimize(input, options: .init(stripMetadata: false, gifRecompress: true))
                XCTAssertTrue(result.changed)
                try assertImageIOIdentity(input, result.data)
            }
        }
    }

    func testAllCodeWidthsAndDictionaryResetsAgainstIndependentDecoder() throws {
        var state: UInt32 = 0x12345678
        for minimum in 2...8 {
            let pixels: [UInt8] = (0..<65536).map { _ in
                state = state &* 1664525 &+ 1013904223
                return UInt8((state >> 16) & UInt32((1 << minimum) - 1))
            }
            let encoded = try XCTUnwrap(GIFLZW.encode(pixels, minimumCodeSize: minimum))
            XCTAssertEqual(GIFLZW.decode(encoded, minimumCodeSize: minimum, expectedCount: pixels.count), pixels)
            let original = makeGIF(frames: [pixels], width: 256, height: 256, minimum: minimum)
            let recoded = makeGIF(frames: [pixels], width: 256, height: 256,
                                  minimum: minimum, compressed: [encoded])
            try assertImageIOIdentity(original, recoded)
        }
    }

    func testImageIOEncodedGIFCanBeRecompressed() throws {
        let width = 128
        var colors = [UInt8]()
        for i in 0..<(width * width) {
            colors.append(UInt8((i * 17) & 255))
            colors.append(UInt8((i / width) & 255))
            colors.append(UInt8(i & 255))
            colors.append(255)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(colors) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: width, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let input = data as Data
        let output = Slimg.optimize(input, options: .init(stripMetadata: false, gifRecompress: true))
        XCTAssertLessThanOrEqual(output.optimizedSize, input.count)
        try assertImageIOIdentity(input, output.data)
    }

    func testMalformedAndOversizedStreamsFallBack() {
        XCTAssertNil(GIFLZW.decode([0xFF], minimumCodeSize: 2, expectedCount: 2))
        XCTAssertNil(GIFLZW.decode([0], minimumCodeSize: 1, expectedCount: 1))
        XCTAssertNil(GIFLZW.decode([0], minimumCodeSize: 2, expectedCount: GIFLZW.maximumPixels + 1))
        XCTAssertNil(GIFLZW.decode(literalStream([0, 1], minimum: 2), minimumCodeSize: 2, expectedCount: 1))
        let original = makeGIF(frames: [[0, 1, 2, 3]], width: 2, height: 2)
        for length in 0..<original.count {
            let truncated = Data(original.prefix(length))
            XCTAssertEqual(Slimg.optimize(truncated, options: .init(stripMetadata: false, gifRecompress: true)).data,
                           truncated)
        }
        let trailing = original + Data([0xAB])
        XCTAssertEqual(Slimg.optimize(trailing, options: .init(stripMetadata: false, gifRecompress: true)).data, trailing)
    }
}
