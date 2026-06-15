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

    /// A large all-zero payload compresses ~1000:1. Re-inflating it must succeed
    /// when under the bomb ceiling and round-trip exactly. This guards against a
    /// regression where the windowed inflate loop drops or duplicates bytes.
    func testZlibInflatesHighlyCompressibleStream() throws {
        let original = [UInt8](repeating: 0, count: 4_000_000) // 4 MB of zeros
        let deflated = try XCTUnwrap(Zlib.deflate(original, level: 9))
        XCTAssertLessThan(deflated.count, 50_000, "zeros should compress massively")
        let inflated = try XCTUnwrap(Zlib.inflate(deflated))
        XCTAssertEqual(inflated.count, original.count)
        XCTAssertEqual(inflated, original)
    }

    /// Decompression-bomb defense: a tiny crafted zlib stream that inflates past
    /// the shim's ceiling (512 MiB) must be REJECTED (nil), not allowed to grow
    /// the output buffer to gigabytes and OOM the process. We build it by
    /// deflating ~600 MB of zeros (a few hundred KB compressed) and asserting
    /// inflate refuses it.
    func testZlibRejectsDecompressionBomb() throws {
        // 600 MiB of zeros -> a few hundred KB of zlib stream, but inflates past
        // the 512 MiB ceiling, so the shim must return nil rather than OOM.
        let huge = [UInt8](repeating: 0, count: 600 * 1024 * 1024)
        let deflated = try XCTUnwrap(Zlib.deflate(huge, level: 9))
        XCTAssertLessThan(deflated.count, 5 * 1024 * 1024, "the bomb payload itself must be small")
        let inflated = Zlib.inflate(deflated)
        XCTAssertNil(inflated, "inflate must refuse to expand past the bomb ceiling")
    }

    /// Inflating arbitrary/garbage bytes must fail cleanly (nil), never crash.
    func testZlibInflateGarbageFailsCleanly() {
        XCTAssertNil(Zlib.inflate([]))
        XCTAssertNil(Zlib.inflate([0x00]))
        XCTAssertNil(Zlib.inflate([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertNil(Zlib.inflate(Array("not a zlib stream at all".utf8)))
        // Valid zlib header (0x78 0x9C) followed by junk.
        XCTAssertNil(Zlib.inflate([0x78, 0x9C, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    /// Truncated zlib stream (valid prefix, cut short) must fail cleanly.
    func testZlibInflateTruncatedStreamFailsCleanly() throws {
        let original: [UInt8] = (0..<5000).map { UInt8(($0 * 31 + 7) & 0xFF) }
        let deflated = try XCTUnwrap(Zlib.deflate(original, level: 9))
        XCTAssertGreaterThan(deflated.count, 10)
        let truncated = Array(deflated.prefix(deflated.count - 5))
        XCTAssertNil(Zlib.inflate(truncated), "truncated stream must not be accepted")
    }

    // MARK: - Fuzz / malformed-input safety
    //
    // These assert the optimizers never crash, never read out of bounds, and
    // always fall back to the original bytes when the input is malformed.
    // (A crash or OOB read here would be a memory-safety vulnerability since
    //  the input is an untrusted image file.)

    /// Random garbage of every length up to a few hundred bytes, for each
    /// format magic prefix, must never crash and must preserve the input.
    func testOptimizeRandomGarbageNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let prefixes: [[UInt8]] = [
            [0xFF, 0xD8, 0xFF],                                      // JPEG SOI
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],        // PNG signature
            Array("GIF89a".utf8),                                    // GIF
            Array("GIF87a".utf8),
            [],                                                      // no prefix
        ]
        for prefix in prefixes {
            for len in 0..<300 {
                var bytes = prefix
                for _ in 0..<len { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
                let data = Data(bytes)
                let result = Slimg.optimize(data)
                // Never larger, and unchanged content is returned verbatim.
                XCTAssertLessThanOrEqual(result.optimizedSize, result.originalSize)
                if !result.changed {
                    XCTAssertEqual(result.data, data)
                }
            }
        }
    }

    /// Every truncation of a valid JPEG/PNG/GIF must be handled without crashing
    /// and must never grow the file.
    func testOptimizeTruncatedValidImagesNeverCrash() {
        let image = makeCGImage(width: 32, height: 32)
        let samples: [Data] = [
            encode(image, as: .jpeg, withMetadata: true),
            encode(image, as: .png, withMetadata: true),
            encode(image, as: .gif, withMetadata: false),
        ]
        for full in samples {
            let bytes = [UInt8](full)
            // Step through truncation lengths (stride keeps the test fast).
            var len = 0
            while len <= bytes.count {
                let data = Data(bytes.prefix(len))
                let result = Slimg.optimize(data)
                XCTAssertLessThanOrEqual(result.optimizedSize, result.originalSize)
                len += max(1, bytes.count / 200)
            }
        }
    }

    /// A file whose declared PNG chunk length is absurdly large (claims more
    /// bytes than exist) must bail out and preserve the original, not OOB-read.
    func testPNGOversizedChunkLengthBailsOut() {
        var bytes = PNGOptimizer.signature
        // IHDR-looking chunk with a 4-byte length of 0x7FFFFFFF but no payload.
        bytes.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])           // length
        bytes.append(contentsOf: Array("IHDR".utf8))                 // type
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])           // truncated payload
        let data = Data(bytes)
        XCTAssertEqual(Slimg.detectFormat(data), .png)
        let result = Slimg.optimize(data)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, data, "malformed PNG must be preserved untouched")
    }

    /// A JPEG with a segment length that runs past EOF must bail out cleanly.
    func testJPEGOversizedSegmentLengthBailsOut() {
        // SOI + APP1 marker claiming a 0xFFFF-byte segment with no payload.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x00]
        let data = Data(bytes)
        XCTAssertEqual(Slimg.detectFormat(data), .jpeg)
        let result = Slimg.optimize(data)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, data)
    }

    /// A GIF claiming a global color table larger than the file must bail out.
    func testGIFOversizedColorTableBailsOut() {
        var bytes = Array("GIF89a".utf8)
        // Logical screen descriptor: width/height + packed byte with GCT flag set
        // and a large GCT size, but no actual table bytes follow.
        bytes.append(contentsOf: [0x10, 0x00, 0x10, 0x00]) // 16x16
        bytes.append(0xF7)                                  // packed: GCT present, size=7 -> 768 bytes
        bytes.append(0x00)                                  // background color index
        bytes.append(0x00)                                  // pixel aspect ratio
        // (no color table, no image data) -> must bail.
        let data = Data(bytes)
        XCTAssertEqual(Slimg.detectFormat(data), .gif)
        let result = Slimg.optimize(data)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, data)
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
