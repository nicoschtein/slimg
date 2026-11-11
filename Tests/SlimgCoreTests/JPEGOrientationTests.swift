import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

/// EXIF stripping must not change how a JPEG is displayed: a non-default
/// Orientation tag survives as a minimal EXIF segment.
final class JPEGOrientationTests: XCTestCase {
    private let keptLabel = "EXIF metadata (APP1), orientation kept"
    private let removedLabel = "EXIF metadata (APP1)"

    // MARK: - Fixtures

    private func makeCGImage(width: Int = 48, height: Int = 32) -> CGImage {
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

    /// An ImageIO-written JPEG, optionally with camera-like EXIF/GPS metadata.
    private func encodeJPEG(orientation: Int? = nil, withMetadata: Bool = false) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if withMetadata {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: String(repeating: "Slimg metadata payload. ", count: 40),
            ]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Slimg Camera",
                kCGImagePropertyTIFFModel: "Test Model",
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, makeCGImage(), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A JPEG with no metadata left to strip: ImageIO output passed through Slimg.
    private func cleanJPEG() -> [UInt8] {
        [UInt8](Slimg.optimize(encodeJPEG()).data)
    }

    private func bytes(_ value: UInt16, _ bigEndian: Bool) -> [UInt8] {
        bigEndian ? [UInt8(value >> 8), UInt8(value & 255)] : [UInt8(value & 255), UInt8(value >> 8)]
    }

    private func bytes(_ value: UInt32, _ bigEndian: Bool) -> [UInt8] {
        let high = bytes(UInt16(value >> 16), bigEndian), low = bytes(UInt16(value & 0xFFFF), bigEndian)
        return bigEndian ? high + low : low + high
    }

    private func app1(_ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 255)] + payload
    }

    /// A complete EXIF APP1 segment whose IFD0 holds an ImageDescription (stored
    /// out of line, to give the segment some bulk) and optionally Orientation.
    private func exifSegment(orientation: UInt16?, bigEndian: Bool, description: Int = 200) -> [UInt8] {
        let entryCount: UInt16 = orientation == nil ? 1 : 2
        let dataOffset = UInt32(8 + 2 + Int(entryCount) * 12 + 4)
        var tiff: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        tiff += bytes(UInt16(42), bigEndian) + bytes(UInt32(8), bigEndian)
        tiff += bytes(entryCount, bigEndian)
        // ImageDescription, ASCII.
        tiff += bytes(UInt16(0x010E), bigEndian) + bytes(UInt16(2), bigEndian)
        tiff += bytes(UInt32(description + 1), bigEndian) + bytes(dataOffset, bigEndian)
        if let orientation {
            tiff += bytes(UInt16(0x0112), bigEndian) + bytes(UInt16(3), bigEndian) + bytes(UInt32(1), bigEndian)
            tiff += bytes(orientation, bigEndian) + [0, 0]
        }
        tiff += bytes(UInt32(0), bigEndian) // no next IFD
        tiff += [UInt8](repeating: 0x41, count: description) + [0]
        return app1(Array("Exif\0\0".utf8) + tiff)
    }

    private func comment(_ text: String) -> [UInt8] {
        let payload = Array(text.utf8)
        let length = payload.count + 2
        return [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 255)] + payload
    }

    /// Inserts segments after SOI and a leading APP0 (JFIF), where EXIF lives.
    private func inserting(_ segments: [UInt8], into jpeg: [UInt8]) -> [UInt8] {
        var index = 2
        if jpeg.count > 6, jpeg[2] == 0xFF, jpeg[3] == 0xE0 {
            index = 4 + (Int(jpeg[4]) << 8 | Int(jpeg[5]))
        }
        var result = jpeg
        result.insert(contentsOf: segments, at: index)
        return result
    }

    private func orientation(_ data: Data) throws -> Int? {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return properties[kCGImagePropertyOrientation] as? Int
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// Decoded RGBA pixels (stored orientation, not display orientation).
    private func pixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    private func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start..<(start + needle.count) }
        }
        return nil
    }

    /// Byte order marker ("II"/"MM") of the first EXIF APP1 in a JPEG.
    private func tiffByteOrder(_ jpeg: [UInt8]) -> [UInt8]? {
        guard let signature = range(of: Array("Exif\0\0".utf8), in: jpeg),
              signature.upperBound + 2 <= jpeg.count else { return nil }
        return Array(jpeg[signature.upperBound..<(signature.upperBound + 2)])
    }

    // MARK: - Orientation kept

    func testCameraJPEGKeepsOrientationSixWithIdenticalPixels() throws {
        let original = encodeJPEG(orientation: 6, withMetadata: true)
        XCTAssertEqual(try orientation(original), 6)
        let byteOrder = try XCTUnwrap(tiffByteOrder([UInt8](original)))
        let bigEndian = byteOrder == [0x4D, 0x4D]

        var huffman = OptimizationOptions()
        huffman.jpegOptimizeHuffman = true
        var progressive = OptimizationOptions()
        progressive.jpegProgressive = true
        for options in [OptimizationOptions(), huffman, progressive] {
            let result = Slimg.optimize(original, options: options)
            XCTAssertTrue(result.changed)
            XCTAssertEqual(try orientation(result.data), 6, "display orientation must survive")
            XCTAssertEqual(try pixels(original), try pixels(result.data), "JPEG pixels must be unchanged")

            // Only the minimal EXIF remains, in the source byte order.
            let output = [UInt8](result.data)
            XCTAssertNotNil(range(of: JPEGOptimizer.minimalEXIF(orientation: 6, bigEndian: bigEndian), in: output))
            XCTAssertEqual(tiffByteOrder(output), byteOrder)
            let metadata = try properties(result.data)
            XCTAssertNil(metadata[kCGImagePropertyGPSDictionary], "GPS must be stripped")
            let tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "camera make must be stripped")
            XCTAssertNil(range(of: Array("Slimg metadata payload".utf8), in: output))

            let item = try XCTUnwrap(result.report.items.first { $0.kind == .exif })
            XCTAssertEqual(item.label, keptLabel)
            XCTAssertGreaterThan(item.bytes, 0)
            XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        }
    }

    func testEveryOrientationInBothByteOrders() throws {
        let clean = cleanJPEG()
        let cleanPixels = try pixels(Data(clean))
        for bigEndian in [false, true] {
            for value in UInt16(2)...8 {
                let segment = exifSegment(orientation: value, bigEndian: bigEndian)
                let input = inserting(segment, into: clean)
                XCTAssertEqual(try orientation(Data(input)), Int(value))

                let result = Slimg.optimize(Data(input))
                let minimal = JPEGOptimizer.minimalEXIF(orientation: value, bigEndian: bigEndian)
                XCTAssertEqual([UInt8](result.data), inserting(minimal, into: clean),
                               "order \(bigEndian ? "MM" : "II"), orientation \(value)")
                XCTAssertEqual(try orientation(result.data), Int(value))
                XCTAssertEqual(try pixels(result.data), cleanPixels)
                XCTAssertEqual(result.report.items.count, 1)
                XCTAssertEqual(result.report.items.first?.kind, .exif)
                XCTAssertEqual(result.report.items.first?.label, keptLabel)
                XCTAssertEqual(result.report.items.first?.bytes, segment.count - minimal.count)
                XCTAssertEqual(result.savedBytes, segment.count - minimal.count)
            }
        }
    }

    func testMinimalSegmentLayout() {
        var little: [UInt8] = [0xFF, 0xE1, 0x00, 0x22]
        little += Array("Exif\0\0".utf8)
        little += [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00] // header, IFD0 at 8
        little += [0x01, 0x00]                                     // one entry
        little += [0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00] // Orientation, SHORT, 1
        little += [0x06, 0x00, 0x00, 0x00]                         // value 6
        little += [0x00, 0x00, 0x00, 0x00]                         // no next IFD
        XCTAssertEqual(JPEGOptimizer.minimalEXIF(orientation: 6, bigEndian: false), little)

        var big: [UInt8] = [0xFF, 0xE1, 0x00, 0x22]
        big += Array("Exif\0\0".utf8)
        big += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        big += [0x00, 0x01]
        big += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]
        big += [0x00, 0x08, 0x00, 0x00]
        big += [0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(JPEGOptimizer.minimalEXIF(orientation: 8, bigEndian: true), big)
    }

    // MARK: - Unchanged behavior

    func testUprightOrMissingOrientationIsDroppedAsBefore() throws {
        let clean = cleanJPEG()
        XCTAssertNil(range(of: Array("Exif\0\0".utf8), in: clean))
        let untouched = Slimg.optimize(Data(clean))
        XCTAssertFalse(untouched.changed, "no EXIF: nothing to do")
        XCTAssertEqual([UInt8](untouched.data), clean)

        for bigEndian in [false, true] {
            for value: UInt16? in [1, nil] {
                let segment = exifSegment(orientation: value, bigEndian: bigEndian)
                let result = Slimg.optimize(Data(inserting(segment, into: clean)))
                XCTAssertEqual([UInt8](result.data), clean, "the EXIF segment is dropped whole")
                XCTAssertEqual(result.report.items.count, 1)
                XCTAssertEqual(result.report.items.first?.kind, .exif)
                XCTAssertEqual(result.report.items.first?.label, removedLabel)
                XCTAssertEqual(result.report.items.first?.bytes, segment.count)
            }
        }
    }

    func testImageIOUprightJPEGDropsEXIFEntirely() throws {
        let original = encodeJPEG(orientation: 1, withMetadata: true)
        let result = Slimg.optimize(original)
        XCTAssertTrue(result.changed)
        XCTAssertNil(range(of: Array("Exif\0\0".utf8), in: [UInt8](result.data)))
        XCTAssertFalse(result.report.items.contains { $0.label == keptLabel })
        XCTAssertEqual(try pixels(original), try pixels(result.data))
    }

    func testKeepMetadataOptionLeavesOrientedEXIFAlone() {
        let original = encodeJPEG(orientation: 6, withMetadata: true)
        let result = Slimg.optimize(original, options: .init(stripMetadata: false))
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, original)
    }

    func testAlreadyMinimalSegmentIsNotRewritten() {
        let clean = cleanJPEG()
        for bigEndian in [false, true] {
            let input = inserting(JPEGOptimizer.minimalEXIF(orientation: 6, bigEndian: bigEndian), into: clean)
            let result = Slimg.optimize(Data(input))
            XCTAssertFalse(result.changed)
            XCTAssertEqual([UInt8](result.data), input)
            XCTAssertTrue(result.report.isEmpty)
        }
    }

    // MARK: - Malformed EXIF is kept verbatim

    func testTruncatedOrMalformedEXIFIsLeftUnchanged() throws {
        let clean = cleanJPEG()
        let note = comment("strip me")

        func le16(_ v: UInt16) -> [UInt8] { bytes(v, false) }
        func le32(_ v: UInt32) -> [UInt8] { bytes(v, false) }
        /// An APP1 segment whose payload is "Exif\0\0" followed by `parts`.
        func exif(_ parts: [UInt8]...) -> [UInt8] { app1(Array("Exif\0\0".utf8) + parts.joined()) }
        let little: [UInt8] = [0x49, 0x49]
        let padding = [UInt8](repeating: 0x20, count: 64)
        func orientationEntry(type: UInt16 = 3, count: UInt32 = 1, value: UInt16 = 6) -> [UInt8] {
            le16(0x0112) + le16(type) + le32(count) + le16(value) + le16(0)
        }

        let full = exifSegment(orientation: 6, bigEndian: false)
        let tiff = Array(full[10...]) // after the marker, length and "Exif\0\0"
        let cases: [(String, [UInt8])] = [
            // Cut short inside the TIFF structure (the APP1 length matches the
            // shortened payload, so the JPEG itself stays well formed).
            ("truncated TIFF header", exif(Array(tiff[0..<3]))),
            ("truncated inside IFD0", exif(Array(tiff[0..<(8 + 2 + 12)]))),
            // IFD0 placed after bulky data, so a lenient parser would find the
            // Orientation entry and the segment would be worth rewriting.
            ("IFD0 cut off after the Orientation entry",
             exif(little, le16(42), le32(72), padding, le16(2), orientationEntry())),
            ("IFD claims more entries than present",
             exif(little, le16(42), le32(72), padding, le16(5), orientationEntry(), le32(0))),
            ("missing next-IFD offset", exif(little, le16(42), le32(72), padding, le16(1), orientationEntry())),
            ("IFD0 offset past end", exif(little, le16(42), le32(4096), padding)),
            ("IFD0 offset inside header", exif(little, le16(42), le32(2), padding)),
            ("unknown byte order", exif([0x49, 0x4D], Array(tiff[2...]))),
            ("bad TIFF magic", exif(little, le16(43), Array(tiff[4...]))),
            ("orientation out of range",
             exif(little, le16(42), le32(8), le16(1), orientationEntry(value: 9), le32(0), padding)),
            ("orientation zero",
             exif(little, le16(42), le32(8), le16(1), orientationEntry(value: 0), le32(0), padding)),
            ("orientation not SHORT",
             exif(little, le16(42), le32(8), le16(1), orientationEntry(type: 4), le32(0), padding)),
            ("orientation count not 1",
             exif(little, le16(42), le32(8), le16(1), orientationEntry(count: 2), le32(0), padding)),
            ("duplicate orientation",
             exif(little, le16(42), le32(8), le16(2), orientationEntry(), orientationEntry(), le32(0), padding)),
        ]

        for (name, segment) in cases {
            let input = inserting(segment + note, into: clean)
            let result = Slimg.optimize(Data(input))
            XCTAssertEqual([UInt8](result.data), inserting(segment, into: clean),
                           "\(name): EXIF kept verbatim, only the comment removed")
            XCTAssertEqual(result.report.items.map(\.kind), [.comment], name)
            XCTAssertEqual(result.savedBytes, note.count, name)
        }
    }
}
