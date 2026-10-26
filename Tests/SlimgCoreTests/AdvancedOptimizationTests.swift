import Foundation
import XCTest
@testable import SlimgCore

final class AdvancedOptimizationTests: XCTestCase {
    private var allMethods: OptimizationOptions {
        .init(stripMetadata: false, pngDeepCompression: true, pngZopfli: true,
              pngReduceRepresentation: true, pngOptimizeStructure: true,
              jpegOptimizeHuffman: true, jpegProgressive: true, gifRecompress: true)
    }

    func testEveryAdditionalMethodDefaultsToOff() {
        let options = OptimizationOptions()
        XCTAssertFalse(options.pngDeepCompression)
        XCTAssertFalse(options.pngZopfli)
        XCTAssertFalse(options.pngReduceRepresentation)
        XCTAssertFalse(options.pngOptimizeStructure)
        XCTAssertFalse(options.jpegOptimizeHuffman)
        XCTAssertFalse(options.jpegProgressive)
        XCTAssertFalse(options.gifRecompress)
        XCTAssertTrue(options.stripMetadata)
        XCTAssertTrue(options.keepColorProfile)
        XCTAssertTrue(options.recompress)
    }

    func testCombinedPNGOptionsStaySmallerThanBaselineAndAccountForSavings() throws {
        func word(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
             UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        func chunk(_ type: String, _ bytes: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + bytes
            return word(bytes.count) + body + word(Int(CRC32.checksum(body)))
        }
        let width = 128, height = 64
        var samples = [UInt8]()
        for y in 0..<height {
            samples.append(0)
            for x in 0..<width { samples += [UInt8((x / 8) % 4 * 70), UInt8(y % 2 * 255), 17, 255] }
        }
        let compressed = try XCTUnwrap(Zlib.deflate(samples, level: 1))
        let header = word(width) + word(height) + [8, 6, 0, 0, 0]
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let bytes = signature + chunk("IHDR", header) + chunk("IDAT", compressed) + chunk("IEND", [])
        let original = Data(bytes)
        let baseline = Slimg.optimize(original, options: .init(stripMetadata: false))
        let combined = Slimg.optimize(original, options: allMethods)
        XCTAssertLessThan(combined.optimizedSize, baseline.optimizedSize)
        XCTAssertEqual(combined.savedBytes, combined.report.bytesAccounted)
        XCTAssertFalse(combined.report.items.contains { $0.kind == .colorProfile })
        let repeated = Slimg.optimize(combined.data, options: allMethods)
        XCTAssertLessThanOrEqual(repeated.optimizedSize, combined.optimizedSize)
        XCTAssertEqual(repeated.savedBytes, repeated.report.bytesAccounted)
    }

    func testAdvancedMethodsRejectMalformedRecognizedFormatsWithoutCrashing() {
        var random: UInt64 = 0xD1CECAFE
        let prefixes: [[UInt8]] = [
            [255, 216, 255],
            [137, 80, 78, 71, 13, 10, 26, 10],
            Array("GIF89a".utf8),
        ]
        for i in 0..<300 {
            let count = i % 128
            var bytes = prefixes[i % prefixes.count]
            for _ in 0..<count {
                random = random &* 6364136223846793005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: random >> 32))
            }
            let input = Data(bytes)
            let result = Slimg.optimize(input, options: allMethods)
            XCTAssertEqual(result.data, input)
            XCTAssertTrue(result.report.isEmpty)
        }
    }
}
