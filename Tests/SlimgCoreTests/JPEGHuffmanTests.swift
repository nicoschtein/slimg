import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

final class JPEGHuffmanTests: XCTestCase {
    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [255, marker, UInt8(length >> 8), UInt8(length & 255)] + payload
    }

    /// A valid 16x16 grayscale JPEG with intentionally inefficient 8-bit codes.
    private func fixture(width: Int = 16, height: Int = 16) -> [UInt8] {
        let quant = segment(219, [0] + [UInt8](repeating: 1, count: 64))
        let frame = segment(192, [8, UInt8(height >> 8), UInt8(height & 255), UInt8(width >> 8), UInt8(width & 255), 1, 1, 0x11, 0])
        var counts = [UInt8](repeating: 0, count: 16)
        counts[7] = 1
        var tables: [UInt8] = [0]
        tables.append(contentsOf: counts)
        tables.append(contentsOf: [0, 16])
        tables.append(contentsOf: counts)
        tables.append(0)
        let huffman = segment(196, tables)
        let scan = segment(218, [1, 1, 0, 0, 63, 0])
        var jpeg: [UInt8] = [255, 216]
        jpeg.append(contentsOf: quant)
        jpeg.append(contentsOf: frame)
        jpeg.append(contentsOf: huffman)
        jpeg.append(contentsOf: scan)
        let blockCount = ((width + 7) / 8) * ((height + 7) / 8)
        jpeg.append(contentsOf: repeatElement(UInt8(0), count: blockCount * 2))
        jpeg.append(contentsOf: [255, 217])
        return jpeg
    }

    private func pixels(_ bytes: [UInt8]) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try result.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    func testHuffmanOptimizationShrinksWithExactEntropyAndPixels() throws {
        let input = fixture()
        let output = try XCTUnwrap(JPEGRecompression.optimize(input))
        XCTAssertLessThan(output.count, input.count)
        XCTAssertEqual(try XCTUnwrap(JPEGTokenReader.tokens(input)), JPEGTokenReader.tokens(output))
        XCTAssertEqual(try pixels(input), try pixels(output))
        XCTAssertTrue(JPEGRecompression.equalCoefficients(input, output))
        XCTAssertNil(JPEGRecompression.optimize(output))
    }

    func testDefaultOffAndMetadataIndependent() throws {
        let input = Data(fixture())
        let defaults = Slimg.optimize(input, options: .init(stripMetadata: false))
        XCTAssertEqual(defaults.data, input)
        var options = OptimizationOptions(stripMetadata: false)
        options.jpegOptimizeHuffman = true
        let result = Slimg.optimize(input, options: options)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertEqual(result.report.items.first?.kind, .recompression)
        XCTAssertEqual(try pixels(Array(input)), try pixels(Array(result.data)))
    }

    func testMetadataAndCodingSavingsAreAccountedTogether() {
        var input = fixture()
        input.insert(contentsOf: segment(254, Array("keep coefficients".utf8)), at: 2)
        var options = OptimizationOptions()
        options.jpegOptimizeHuffman = true
        let result = Slimg.optimize(Data(input), options: options)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertEqual(Set(result.report.items.map(\.kind)), [.comment, .recompression])
    }

    func testInterpretationMarkersArePreserved() throws {
        let adobe = segment(238, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 0])
        let icc = segment(226, Array("ICC_PROFILE\0".utf8) + [1, 1, 4, 5, 6])
        var input = fixture()
        input.insert(contentsOf: adobe + icc, at: 2)
        let output = try XCTUnwrap(JPEGRecompression.optimize(input))
        XCTAssertEqual(Array(output[2..<(2 + adobe.count + icc.count)]), adobe + icc)
        XCTAssertEqual(JPEGTokenReader.tokens(input), JPEGTokenReader.tokens(output))
    }

    func testRejectsUnsupportedAndMalformedCoding() throws {
        let baseline = fixture()
        var progressive = baseline
        let frameIndex = try XCTUnwrap(progressive.indices.dropLast().first(where: { progressive[$0] == 255 && progressive[$0 + 1] == 192 }))
        progressive[frameIndex + 1] = 194
        XCTAssertNil(JPEGRecompression.optimize(progressive))
        var restart = baseline
        restart.insert(contentsOf: segment(221, [0, 1]), at: 2)
        XCTAssertNil(JPEGRecompression.optimize(restart))
        var trailing = baseline
        trailing.append(0)
        XCTAssertNil(JPEGRecompression.optimize(trailing))
        for end in 0..<baseline.count {
            XCTAssertNil(JPEGRecompression.optimize(Array(baseline.prefix(end))))
        }
        var extraEntropy = baseline
        extraEntropy.insert(0, at: extraEntropy.count - 2)
        XCTAssertNil(JPEGRecompression.optimize(extraEntropy))
        var oversized = baseline
        oversized[frameIndex + 5] = 255
        oversized[frameIndex + 6] = 255
        oversized[frameIndex + 7] = 255
        oversized[frameIndex + 8] = 255
        XCTAssertNil(JPEGRecompression.optimize(oversized))
    }

    func testImageIOGeneratedColorAndGrayJPEGsStayExact() throws {
        for (width, height) in [(1, 1), (17, 19), (64, 48), (101, 81)] {
            for grayscale in [false, true] {
                let channels = grayscale ? 1 : 3
                var bytes = [UInt8](repeating: 0, count: width * height * channels)
                for y in 0..<height {
                    for x in 0..<width {
                        for channel in 0..<channels {
                            bytes[(y * width + x) * channels + channel] = UInt8((x * (13 + channel) + y * 7) & 255)
                        }
                    }
                }
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: channels * 8, bytesPerRow: width * channels,
                    space: grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let data = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let input = [UInt8](data as Data)
                XCTAssertNotNil(JPEGTokenReader.tokens(input), "\(width)x\(height) grayscale=\(grayscale)")
                if let output = JPEGRecompression.optimize(input) {
                    XCTAssertLessThan(output.count, input.count)
                    XCTAssertTrue(JPEGRecompression.equalCoefficients(input, output))
                    XCTAssertEqual(try pixels(input), try pixels(output))
                }
            }
        }
    }

    func testProgressiveRecodingAndBestCandidatePreserveCoefficients() throws {
        let input = fixture(width: 256, height: 256)
        let baseline = try XCTUnwrap(JPEGRecompression.optimize(input))
        let progressive = try XCTUnwrap(JPEGRecompression.optimize(input, progressive: true))
        XCTAssertTrue(progressive.indices.dropLast().contains { progressive[$0] == 255 && progressive[$0 + 1] == 194 })
        XCTAssertTrue(JPEGRecompression.equalCoefficients(input, progressive))
        XCTAssertEqual(try pixels(input), try pixels(progressive))
        var options = OptimizationOptions(stripMetadata: false)
        options.jpegProgressive = true
        let onlyProgressive = Slimg.optimize(Data(input), options: options)
        XCTAssertEqual(onlyProgressive.optimizedSize, progressive.count)
        XCTAssertEqual(onlyProgressive.report.bytesAccounted, onlyProgressive.savedBytes)
        options.jpegOptimizeHuffman = true
        let both = Slimg.optimize(Data(input), options: options)
        XCTAssertEqual(both.optimizedSize, min(baseline.count, progressive.count))
        XCTAssertTrue(JPEGRecompression.equalCoefficients(input, Array(both.data)))
        if let sequential = JPEGRecompression.optimize(progressive) {
            XCTAssertTrue(JPEGRecompression.equalCoefficients(progressive, sequential))
            XCTAssertEqual(try pixels(progressive), try pixels(sequential))
        }
    }

    func testRejectsAuxiliaryImageIndexesAndNonImages() {
        var input = fixture()
        input.insert(contentsOf: segment(226, Array("MPF\0".utf8) + [1, 2, 3, 4]), at: 2)
        XCTAssertNil(JPEGRecompression.optimize(input))
        XCTAssertFalse(JPEGRecompression.equalCoefficients(input, [255, 216, 255, 217]))
        for count in 0..<256 {
            let bytes = [UInt8](repeating: UInt8(count), count: count)
            XCTAssertNil(JPEGRecompression.optimize(bytes, progressive: count % 2 == 0))
        }
    }

    func testCMYKImageIOJPEGPreservesPixelsAndCoefficients() throws {
        let width = 64, height = 48
        var raw = [UInt8]()
        for index in 0..<(width * height * 4) {
            let value = (index * 13 + index / 71) & 255
            raw.append(UInt8(value))
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(raw) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceCMYK(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let input = [UInt8](data as Data)
        var successful = 0
        for progressive in [false, true] {
            if let output = JPEGRecompression.optimize(input, progressive: progressive) {
                successful += 1
                XCTAssertTrue(JPEGRecompression.equalCoefficients(input, output))
                XCTAssertEqual(try pixels(input), try pixels(output))
            }
        }
        XCTAssertGreaterThan(successful, 0)
    }


    func testRejectsLateMetadataAndDetectsChangedQuantization() {
        let input = fixture()
        var late = input
        late.insert(contentsOf: segment(254, Array("late metadata".utf8)), at: late.count - 2)
        XCTAssertNil(JPEGRecompression.optimize(late))
        var changedQuantization = input
        changedQuantization[7] = 2
        XCTAssertFalse(JPEGRecompression.equalCoefficients(input, changedQuantization))
    }

    func testEXIFOrientationSurvivesBothCodingModes() throws {
        let exif: [UInt8] = Array("Exif\0\0".utf8) + [
            0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 1, 0,
            0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
        ]
        let marker = segment(225, exif)
        var input = fixture(width: 256, height: 256)
        input.insert(contentsOf: marker, at: 2)
        for progressive in [false, true] {
            let output = try XCTUnwrap(JPEGRecompression.optimize(input, progressive: progressive))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(output) as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
            XCTAssertEqual(Array(output[2..<(2 + marker.count)]), marker)
            XCTAssertTrue(JPEGRecompression.equalCoefficients(input, output))
        }
    }

}
