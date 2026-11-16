import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

/// Metadata outside the image header must go too: between the scans of a
/// progressive JPEG, and after the end-of-image marker, where phones and
/// editors append extra images (MPF: HDR gain maps, depth maps) and motion
/// photo videos that carry their own EXIF and location.
final class JPEGEmbeddedDataTests: XCTestCase, JPEGFixtures {
    private struct NoScan: Error {}

    private let location = "+37.7749-122.4194/"

    // MARK: - Fixtures

    /// An ImageIO-written JPEG, optionally progressive, optionally with camera
    /// make and GPS location in its EXIF.
    private func encodeJPEG(width: Int = 96, height: Int = 64, progressive: Bool = false,
                            withLocation: Bool = false) -> [UInt8] {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if progressive {
            properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        if withLocation {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Slimg Camera"]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, makeCGImage(width: width, height: height), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](output as Data)
    }

    /// What Slimg makes of `jpeg` alone: the expected output once anything
    /// hidden in or appended to it is removed.
    private func stripped(_ jpeg: [UInt8]) -> [UInt8] {
        [UInt8](Slimg.optimize(Data(jpeg)).data)
    }

    /// Index of the first marker after the first scan's entropy-coded data.
    /// Assumes a header without fill bytes or standalone markers, as ImageIO
    /// writes it.
    private func endOfFirstScan(_ jpeg: [UInt8]) throws -> Int {
        var i = 2
        while i + 3 < jpeg.count, jpeg[i] == 0xFF {
            let marker = jpeg[i + 1]
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            if marker == 0xDA {
                var k = i + 2 + length
                while k + 1 < jpeg.count {
                    let next = jpeg[k + 1]
                    if jpeg[k] == 0xFF, next != 0x00, !(0xD0...0xD7).contains(next) { return k }
                    k += 1
                }
                break
            }
            i += 2 + length
        }
        throw NoScan()
    }

    private func labels(_ result: OptimizationResult) -> [String] {
        result.report.items.map(\.label)
    }

    // MARK: - After the end of the image

    func testAppendedImageWithLocationIsRemoved() throws {
        let primary = encodeJPEG()
        let secondary = encodeJPEG(width: 32, height: 24, withLocation: true)
        XCTAssertNotNil(range(of: Array("Slimg Camera".utf8), in: secondary))
        let input = primary + secondary

        let result = Slimg.optimize(Data(input))
        let output = [UInt8](result.data)
        XCTAssertEqual(output, stripped(primary))
        XCTAssertNil(range(of: Array("Slimg Camera".utf8), in: output))
        XCTAssertNil(range(of: Array("Exif\0\0".utf8), in: output))
        XCTAssertTrue(result.report.items.contains {
            $0.label == "Embedded image after end of image" && $0.bytes == secondary.count
        }, "\(labels(result))")
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertEqual(try pixels(Data(output)), try pixels(Data(input)))
    }

    /// The MPF index (APP2) that points at the appended image goes with it.
    func testMPFIndexAndItsImageAreRemoved() throws {
        let primary = encodeJPEG()
        let secondary = encodeJPEG(width: 32, height: 24, withLocation: true)
        // "MPF\0" followed by a big-endian TIFF header; the index entries
        // themselves don't matter to the stripper.
        let mpf = segment(0xE2, Array("MPF\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
                              + [UInt8](repeating: 0, count: 40))
        let input = inserting(mpf, into: primary) + secondary

        let result = Slimg.optimize(Data(input))
        let output = [UInt8](result.data)
        XCTAssertEqual(output, stripped(primary))
        XCTAssertNil(range(of: Array("MPF\0".utf8), in: output))
        XCTAssertTrue(labels(result).contains("Application data (APP2)"), "\(labels(result))")
        XCTAssertTrue(labels(result).contains("Embedded image after end of image"), "\(labels(result))")
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertEqual(try pixels(Data(output)), try pixels(Data(input)))
    }

    func testMotionPhotoVideoIsRemoved() throws {
        let primary = encodeJPEG()
        var video = Array("MotionPhoto_Data".utf8)
        video += [0x00, 0x00, 0x00, 0x18] + Array("ftypmp42".utf8) + [UInt8](repeating: 0, count: 12)
        video += Array("udta xyz \(location)".utf8) + [UInt8](repeating: 0x5A, count: 400)
        let input = primary + video

        let result = Slimg.optimize(Data(input))
        let output = [UInt8](result.data)
        XCTAssertEqual(output, stripped(primary))
        XCTAssertNil(range(of: Array(location.utf8), in: output))
        XCTAssertTrue(result.report.items.contains {
            $0.label == "Embedded video after end of image (motion photo)" && $0.bytes == video.count
        }, "\(labels(result))")
        XCTAssertEqual(try pixels(Data(output)), try pixels(Data(input)))
    }

    func testOtherAppendedDataIsRemoved() throws {
        let primary = encodeJPEG()
        let tail = Array("appended by some editor \(location)".utf8) + [UInt8](repeating: 0, count: 64)
        let result = Slimg.optimize(Data(primary + tail))
        XCTAssertEqual([UInt8](result.data), stripped(primary))
        XCTAssertTrue(result.report.items.contains {
            $0.label == "Data after end of image" && $0.bytes == tail.count
        }, "\(labels(result))")
    }

    /// With metadata kept (only the color profile stripped), appended data is
    /// left alone like every other metadata segment.
    func testKeepingMetadataKeepsAppendedData() {
        let tail = Array("appended \(location)".utf8)
        let input = encodeJPEG() + tail
        let result = Slimg.optimize(Data(input), options: OptimizationOptions(stripMetadata: false, keepColorProfile: false))
        XCTAssertEqual(Array([UInt8](result.data).suffix(tail.count)), tail)
        XCTAssertFalse(result.report.items.contains { $0.label.contains("after end of image") })
    }

    // MARK: - Between progressive scans

    func testMetadataBetweenProgressiveScansIsRemoved() throws {
        func scanCount(_ jpeg: [UInt8]) -> Int {
            jpeg.indices.dropLast().filter { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA }.count
        }
        var progressive = encodeJPEG(width: 128, height: 96, progressive: true)
        if scanCount(progressive) < 2, let recoded = JPEGRecompression.optimize(progressive, progressive: true) {
            progressive = recoded
        }
        XCTAssertGreaterThan(scanCount(progressive), 1, "expected a multi-scan progressive JPEG")

        let cut = try endOfFirstScan(progressive)
        let hidden = comment("Slimg hidden comment")
            + app1(Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>Slimg hidden XMP \(location)</x:xmpmeta>".utf8))
        let input = Array(progressive[..<cut]) + hidden + Array(progressive[cut...])

        let result = Slimg.optimize(Data(input))
        let output = [UInt8](result.data)
        XCTAssertEqual(output, stripped(progressive))
        XCTAssertNil(range(of: Array("Slimg hidden".utf8), in: output))
        XCTAssertTrue(labels(result).contains("Comment (COM)"), "\(labels(result))")
        XCTAssertTrue(labels(result).contains("XMP metadata (APP1)"), "\(labels(result))")
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertEqual(try pixels(Data(output)), try pixels(Data(input)))
        XCTAssertTrue(JPEGRecompression.equalCoefficients(input, output))

        // Every truncation is handled without crashing or growing the file.
        var length = 0
        while length <= input.count {
            let truncated = Slimg.optimize(Data(input.prefix(length)))
            XCTAssertLessThanOrEqual(truncated.optimizedSize, truncated.originalSize)
            length += max(1, input.count / 150)
        }
    }

    func testMetadataBeforeEndOfImageIsRemoved() throws {
        let primary = encodeJPEG()
        XCTAssertEqual(Array(primary.suffix(2)), [0xFF, 0xD9])
        let input = Array(primary.dropLast(2)) + comment("Slimg hidden comment") + [0xFF, 0xD9]
        let result = Slimg.optimize(Data(input))
        XCTAssertEqual([UInt8](result.data), stripped(primary))
        XCTAssertTrue(labels(result).contains("Comment (COM)"), "\(labels(result))")
    }

    // MARK: - Scan data

    /// Stuffed bytes and restart markers belong to the scan; the next other
    /// marker (here after fill bytes) ends it.
    func testScanDataRunsToTheNextMarker() {
        let scan: [UInt8] = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD3, 0x56, 0xFF, 0xFF, 0xD9]
        XCTAssertEqual(JPEGOptimizer.entropyCodedEnd(scan, from: 0), 7)
        XCTAssertEqual(JPEGOptimizer.entropyCodedEnd([0x12, 0xFF, 0x00, 0x34], from: 0), 4)
        XCTAssertEqual(JPEGOptimizer.entropyCodedEnd([0x12, 0xFF], from: 0), 2)
        XCTAssertEqual(JPEGOptimizer.entropyCodedEnd([], from: 0), 0)
    }

    /// Once appended data is gone the file ends at its end-of-image marker, so
    /// the optional Huffman recoding can run on it; its output must still hold
    /// the main image's exact coefficients.
    func testHuffmanOptimizationStaysExactWithAppendedData() throws {
        let primary = encodeJPEG()
        let input = primary + encodeJPEG(width: 32, height: 24, withLocation: true)
        var options = OptimizationOptions()
        options.jpegOptimizeHuffman = true
        let result = Slimg.optimize(Data(input), options: options)
        let output = [UInt8](result.data)
        XCTAssertLessThanOrEqual(output.count, stripped(primary).count)
        XCTAssertTrue(JPEGRecompression.equalCoefficients(primary, output))
        XCTAssertEqual(try pixels(Data(output)), try pixels(Data(primary)))
    }
}
