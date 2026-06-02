import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

final class SlimgCoreTests: XCTestCase {

    // MARK: - Helpers

    /// A small image with some structure so compression is meaningful.
    private func makeCGImage(width: Int = 48, height: Int = 48) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.80, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.20, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.85, blue: 0.30, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    private func encode(_ image: CGImage, as type: UTType, withMetadata: Bool) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        if withMetadata {
            // Bulky EXIF + GPS for JPEG; description for PNG -> text chunk.
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: String(repeating: "Slimg metadata payload. ", count: 60),
                kCGImagePropertyExifMakerNote: String(repeating: "X", count: 400),
            ]
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
            props[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGDescription: String(repeating: "Slimg PNG description metadata. ", count: 60),
            ]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "Failed to encode test image")
        return out as Data
    }

    /// Decode to raw RGBA pixels for byte-for-byte comparison.
    private func pixels(_ data: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for i in 0...(haystack.count - needle.count) {
            var match = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] {
                match = false
                break
            }
            if match { return true }
        }
        return false
    }

    // MARK: - JPEG

    func testJPEGStripsMetadataLosslessly() throws {
        let image = makeCGImage()
        let original = encode(image, as: .jpeg, withMetadata: true)

        XCTAssertEqual(Slimg.detectFormat(original), .jpeg)
        // APP1 marker (EXIF/XMP) present in the original.
        XCTAssertTrue(contains([UInt8](original), [0xFF, 0xE1]), "expected EXIF APP1 marker in source")

        let result = Slimg.optimize(original)
        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(result.changed, "expected JPEG to shrink after metadata strip")
        XCTAssertLessThan(result.optimizedSize, result.originalSize)

        // APP1 gone from the optimized data.
        XCTAssertFalse(contains([UInt8](result.data), [0xFF, 0xE1]), "EXIF APP1 should be stripped")

        // Pixels byte-for-byte identical (no re-encode of scan data).
        let before = try XCTUnwrap(pixels(original))
        let after = try XCTUnwrap(pixels(result.data))
        XCTAssertEqual(before, after, "JPEG pixels must be unchanged")
    }

    func testJPEGReportListsRemovedMetadata() {
        let image = makeCGImage()
        let original = encode(image, as: .jpeg, withMetadata: true)
        let result = Slimg.optimize(original)

        XCTAssertFalse(result.report.isEmpty, "report should list removed items")
        XCTAssertTrue(result.report.items.contains { $0.kind == .exif && $0.bytes > 0 },
                      "report should include EXIF removal with a byte count")
        // No lossless re-compression entry for JPEG (scan data is never touched).
        XCTAssertFalse(result.report.items.contains { $0.kind == .recompression })
        // Reported metadata bytes should be a meaningful fraction of what was saved.
        XCTAssertGreaterThan(result.report.metadataBytes, 0)
        XCTAssertLessThanOrEqual(result.report.metadataBytes, result.savedBytes + 4)
    }

    func testPNGReportListsChunksAndRecompression() {
        let image = makeCGImage(width: 80, height: 80)
        let original = encode(image, as: .png, withMetadata: true)
        let result = Slimg.optimize(original)

        XCTAssertFalse(result.report.isEmpty)
        // Some text/metadata chunk was removed.
        XCTAssertTrue(result.report.items.contains {
            $0.kind == .textMetadata || $0.kind == .exif || $0.kind == .xmp
        }, "expected a metadata chunk in the report")
    }

    func testUnknownFormatReportIsEmpty() {
        let result = Slimg.optimize(Data([0, 1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertTrue(result.report.isEmpty)
    }

    func testJPEGKeepMetadataOptionLeavesItAlone() {
        let image = makeCGImage()
        let original = encode(image, as: .jpeg, withMetadata: true)
        let result = Slimg.optimize(original, options: .init(stripMetadata: false, keepColorProfile: true, recompress: true))
        XCTAssertEqual(result.optimizedSize, result.originalSize)
        XCTAssertFalse(result.changed)
    }

    // MARK: - PNG

    func testPNGStripsMetadataLosslessly() throws {
        let image = makeCGImage()
        let original = encode(image, as: .png, withMetadata: true)

        XCTAssertEqual(Slimg.detectFormat(original), .png)

        let result = Slimg.optimize(original)
        XCTAssertEqual(result.format, .png)

        // Pixels identical.
        let before = try XCTUnwrap(pixels(original))
        let after = try XCTUnwrap(pixels(result.data))
        XCTAssertEqual(before, after, "PNG pixels must be unchanged")

        // No text metadata chunks remain.
        let bytes = [UInt8](result.data)
        for marker in ["tEXt", "zTXt", "iTXt", "tIME", "eXIf"] {
            XCTAssertFalse(contains(bytes, Array(marker.utf8)), "\(marker) chunk should be stripped")
        }
    }

    func testPNGRecompressionNeverGrowsAndStaysLossless() throws {
        let image = makeCGImage(width: 64, height: 64)
        let original = encode(image, as: .png, withMetadata: false)
        let result = Slimg.optimize(original)
        XCTAssertEqual(result.format, .png)
        XCTAssertLessThanOrEqual(result.optimizedSize, result.originalSize, "must never grow")

        let before = try XCTUnwrap(pixels(original))
        let after = try XCTUnwrap(pixels(result.data))
        XCTAssertEqual(before, after)
    }

    // MARK: - Zlib round trip

    func testZlibRoundTrip() throws {
        let original: [UInt8] = (0..<5000).map { UInt8(($0 * 7 + 13) & 0xFF) }
        let deflated = try XCTUnwrap(Zlib.deflate(original, level: 9))
        let inflated = try XCTUnwrap(Zlib.inflate(deflated))
        XCTAssertEqual(original, inflated)
    }

    // MARK: - Unknown format

    func testUnknownFormatIsUntouched() {
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let result = Slimg.optimize(junk)
        XCTAssertEqual(result.format, .unknown)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, junk)
    }
}
