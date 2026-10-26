import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SlimgCore

final class PNGCompressionTests: XCTestCase {
    private func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    private func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        return be32(payload.count) + body + be32(Int(CRC32.checksum(body)))
    }

    private func makePNG(width: Int = 256, height: Int = 128, depth: UInt8 = 8, color: UInt8 = 2,
                         rows: [UInt8]? = nil, split: Int = 1, profile: [UInt8]? = nil,
                         extras: [(String, [UInt8])] = [], interlace: UInt8 = 0) throws -> Data {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(color)]!
        let rowBytes = (width * channels * Int(depth) + 7) / 8
        var raw = rows ?? []
        if rows == nil {
            for y in 0..<height {
                for x in 0..<width {
                    raw.append(UInt8(x & 255))
                    raw.append(UInt8((x + y) & 255))
                    raw.append(UInt8(255 - (x & 255)))
                }
            }
        }
        XCTAssertEqual(raw.count, rowBytes * height)
        var filtered = [UInt8]()
        for y in 0..<height { filtered += [0] + raw[(y * rowBytes)..<((y + 1) * rowBytes)] }
        let compressed = try XCTUnwrap(Zlib.deflate(filtered))
        var result = PNGOptimizer.signature
        result += chunk("IHDR", be32(width) + be32(height) + [depth, color, 0, 0, interlace])
        if color == 3 { result += chunk("PLTE", (0..<(1 << Int(depth))).flatMap { [UInt8($0), UInt8($0), UInt8($0)] }) }
        if let profile { result += chunk("iCCP", Array("sRGB".utf8) + [0, 0] + (try XCTUnwrap(Zlib.deflate(profile, level: 0)))) }
        for (type, value) in extras { result += chunk(type, value) }
        for i in 0..<split {
            let start = i * compressed.count / split
            let end = (i + 1) * compressed.count / split
            result += chunk("IDAT", Array(compressed[start..<end]))
        }
        result += chunk("IEND", [])
        return Data(result)
    }

    private func payloads(_ data: Data, _ wanted: String) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var result = [[UInt8]](), offset = 8
        while offset + 12 <= bytes.count {
            let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if type == wanted { result.append(Array(bytes[offset + 8..<offset + 8 + count])) }
            offset += 12 + count
        }
        return result
    }

    private func rawSamples(_ data: Data) throws -> [UInt8] {
        let header = try XCTUnwrap(payloads(data, "IHDR").first)
        let layout = try XCTUnwrap(PNGFiltering.Layout(header))
        let filtered = try XCTUnwrap(Zlib.inflate(payloads(data, "IDAT").flatMap { $0 }))
        return try XCTUnwrap(PNGFiltering.unfilter(filtered, layout: layout))
    }

    private func assertImageIOEquivalent(_ original: Data, _ optimized: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        func image(_ data: Data) throws -> CGImage {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let before = try image(original), after = try image(optimized)
        XCTAssertEqual(before.width, after.width, file: file, line: line)
        XCTAssertEqual(before.height, after.height, file: file, line: line)
        XCTAssertEqual(before.bitsPerComponent, after.bitsPerComponent, file: file, line: line)
        XCTAssertEqual(before.bitsPerPixel, after.bitsPerPixel, file: file, line: line)
        XCTAssertEqual(before.bitmapInfo, after.bitmapInfo, file: file, line: line)
        XCTAssertEqual(before.dataProvider?.data as Data?, after.dataProvider?.data as Data?, file: file, line: line)
    }

    func testNewOptionsDefaultOff() throws {
        let original = try makePNG(split: 4)
        let defaults = OptimizationOptions()
        XCTAssertFalse(defaults.pngDeepCompression)
        XCTAssertFalse(defaults.pngOptimizeStructure)
        XCTAssertFalse(defaults.pngReduceRepresentation)
        XCTAssertFalse(defaults.pngZopfli)
        XCTAssertEqual(Slimg.optimize(original, options: .init(stripMetadata: false)).data, original)
    }

    func testFilterSearchActuallyBeatsExistingLevelNine() throws {
        let original = try makePNG(extras: [("gAMA", [0, 0, 177, 143])])
        let baseline = Slimg.optimize(original, options: .init(stripMetadata: false))
        var options = OptimizationOptions(stripMetadata: false)
        options.pngDeepCompression = true
        let optimized = Slimg.optimize(original, options: options)
        XCTAssertLessThan(optimized.optimizedSize, baseline.optimizedSize)
        XCTAssertEqual(try rawSamples(original), try rawSamples(optimized.data))
        XCTAssertEqual(payloads(original, "gAMA"), payloads(optimized.data, "gAMA"))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(optimized.data as CFData, nil)), 0, nil))
        try assertImageIOEquivalent(original, optimized.data)
        XCTAssertEqual(optimized.savedBytes, optimized.report.bytesAccounted)
        print("PNG deep filter fixture: \(baseline.optimizedSize) -> \(optimized.optimizedSize) bytes")
    }

    func testEveryDepthAndColorTypePreservesNativeBytesIncludingHiddenRGB() throws {
        let formats: [(UInt8, [UInt8], Int)] = [(0, [1, 2, 4, 8, 16], 1), (2, [8, 16], 3), (3, [1, 2, 4, 8], 1), (4, [8, 16], 2), (6, [8, 16], 4)]
        for (color, depths, channels) in formats {
            for depth in depths {
                let width = 37, height = 13
                let size = ((width * channels * Int(depth) + 7) / 8) * height
                var rows = [UInt8]()
                for index in 0..<size { rows.append(UInt8((index * 71 + index / 17) & 255)) }
                if color == 6 {
                    // Fully transparent pixels retain their nonzero RGB bytes.
                    let sampleBytes = Int(depth / 8)
                    for offset in stride(from: 3 * sampleBytes, to: size, by: 4 * sampleBytes) {
                        for byte in 0..<sampleBytes { rows[offset + byte] = 0 }
                    }
                }
                let original = try makePNG(width: width, height: height, depth: depth, color: color, rows: rows)
                var options = OptimizationOptions(stripMetadata: false)
                options.pngDeepCompression = true
                let result = Slimg.optimize(original, options: options)
                XCTAssertEqual(try rawSamples(result.data), rows, "color \(color), depth \(depth)")
                XCTAssertLessThanOrEqual(result.optimizedSize, original.count)
                XCTAssertEqual(payloads(original, "IHDR"), payloads(result.data, "IHDR"))
                try assertImageIOEquivalent(original, result.data)
            }
        }
    }

    func testAllFiveFiltersRoundTripNativeBytes() throws {
        let header = be32(19) + be32(7) + [16, 6, 0, 0, 0]
        let layout = try XCTUnwrap(PNGFiltering.Layout(header))
        let rows = (0..<(layout.rowBytes * layout.height)).map { UInt8(($0 * 57 + 193) & 255) }
        for type: UInt8 in 0...4 {
            XCTAssertEqual(PNGFiltering.unfilter(PNGFiltering.filter(rows, layout: layout, type: type), layout: layout), rows)
        }
        XCTAssertEqual(PNGFiltering.unfilter(PNGFiltering.filter(rows, layout: layout, type: nil), layout: layout), rows)
    }

    func testZlibStrategiesPreserveBytesAndImproveRunLengthFixture() throws {
        var state: UInt32 = 123
        var raw = [UInt8]()
        for _ in 0..<20000 {
            state = state &* 1664525 &+ 1013904223
            raw.append(UInt8(state >> 30))
        }
        let baseline = try XCTUnwrap(Zlib.deflate(raw))
        var best = baseline.count
        for strategy: Int32 in 0...4 {
            let compressed = try XCTUnwrap(Zlib.deflate(raw, strategy: strategy))
            XCTAssertEqual(Zlib.inflate(compressed), raw)
            best = min(best, compressed.count)
        }
        XCTAssertLessThan(best, baseline.count)
        print("PNG strategy fixture: \(baseline.count) -> \(best) compressed bytes")
    }

    func testStructureConsolidatesIDATWithoutRecompression() throws {
        let original = try makePNG(split: 9)
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngOptimizeStructure = true
        let result = Slimg.optimize(original, options: options)
        XCTAssertEqual(result.savedBytes, 8 * 12)
        XCTAssertEqual(payloads(original, "IDAT").flatMap { $0 }, payloads(result.data, "IDAT").flatMap { $0 })
        XCTAssertEqual(payloads(result.data, "IDAT").count, 1)
        XCTAssertEqual(try rawSamples(original), try rawSamples(result.data))
        XCTAssertEqual(result.savedBytes, result.report.bytesAccounted)
    }

    func testRecompressesICCWithoutAlteringProfile() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let profile = [UInt8](try XCTUnwrap(space.copyICCData()) as Data)
        let original = try makePNG(profile: profile)
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngOptimizeStructure = true
        let result = Slimg.optimize(original, options: options)
        XCTAssertLessThan(result.optimizedSize, original.count)
        let after = try XCTUnwrap(payloads(result.data, "iCCP").first)
        XCTAssertEqual(Zlib.inflate(Array(after[6...])), profile)
        XCTAssertEqual(try rawSamples(original), try rawSamples(result.data))
        XCTAssertEqual(result.savedBytes, result.report.bytesAccounted)
        print("PNG ICC fixture: \(original.count) -> \(result.optimizedSize) bytes")
    }

    func testAdvancedMethodsLeaveUnsupportedImagesAlone() throws {
        for extras in [[("acTL", be32(1) + be32(0))], [("vpAG", [1, 2, 3])]] {
            let original = try makePNG(split: 3, extras: extras)
            var options = OptimizationOptions(stripMetadata: false, recompress: false)
            options.pngOptimizeStructure = true; options.pngDeepCompression = true
            options.pngReduceRepresentation = true; options.pngZopfli = true
            XCTAssertEqual(Slimg.optimize(original, options: options).data, original)
        }
        let interlaced = try makePNG(split: 2, interlace: 1)
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngOptimizeStructure = true; options.pngDeepCompression = true
        options.pngReduceRepresentation = true; options.pngZopfli = true
        XCTAssertEqual(Slimg.optimize(interlaced, options: options).data, interlaced)
    }

    func testMalformedPNGAndStreamsArePreserved() throws {
        let original = try makePNG()
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngDeepCompression = true; options.pngOptimizeStructure = true
        var badCRC = original
        badCRC[badCRC.count - 1] ^= 1
        XCTAssertEqual(Slimg.optimize(badCRC, options: options).data, badCRC)
        var noEnd = original; noEnd.removeLast(12)
        XCTAssertEqual(Slimg.optimize(noEnd, options: options).data, noEnd)
        let unknown = try makePNG(extras: [("ABCD", [1, 2, 3])])
        XCTAssertEqual(Slimg.optimize(unknown, options: options).data, unknown)
        let compressed = try XCTUnwrap(Zlib.deflate([1, 2, 3]))
        XCTAssertNil(Zlib.inflate(compressed + [0]))
        XCTAssertNil(Zlib.inflate(compressed, maximumSize: 2))
        XCTAssertNil(PNGFiltering.Layout(be32(0x7FFF_FFFF) + be32(0x7FFF_FFFF) + [16, 6, 0, 0, 0]))
    }

    func testZopfliCompressesExactlyAndHasInputLimit() throws {
        var state: UInt32 = 123
        var raw = [UInt8]()
        for _ in 0..<16000 {
            state = state &* 1664525 &+ 1013904223
            raw.append(UInt8(state >> 30))
        }
        let compressed = try XCTUnwrap(Zopfli.compress(raw))
        let baseline = try XCTUnwrap(Zlib.deflate(raw))
        XCTAssertLessThan(compressed.count, baseline.count)
        XCTAssertEqual(Zlib.inflate(compressed), raw)
        XCTAssertNil(Zopfli.compress([]))
        XCTAssertNil(Zopfli.compress([UInt8](repeating: 0, count: Zopfli.maximumSize + 1)))
        print("PNG Zopfli raw fixture: \(baseline.count) -> \(compressed.count) bytes")
    }

    func testZopfliCanImproveDeepPNGWithoutPixelChanges() throws {
        let original = try makePNG()
        var deep = OptimizationOptions(stripMetadata: false)
        deep.pngDeepCompression = true
        let baseline = Slimg.optimize(original, options: deep)
        deep.pngZopfli = true
        let result = Slimg.optimize(original, options: deep)
        XCTAssertLessThan(result.optimizedSize, baseline.optimizedSize)
        XCTAssertEqual(try rawSamples(result.data), try rawSamples(original))
        try assertImageIOEquivalent(original, result.data)
        XCTAssertEqual(result.savedBytes, result.report.bytesAccounted)
        XCTAssertTrue(result.report.items.contains { $0.label.contains("Zopfli") })
        print("PNG Zopfli after deep fixture: \(baseline.optimizedSize) -> \(result.optimizedSize) bytes")
    }

    func testZopfliOnlyOptionIsIndependentOfRegularRecompression() throws {
        let original = try makePNG()
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngZopfli = true
        let result = Slimg.optimize(original, options: options)
        XCTAssertLessThanOrEqual(result.optimizedSize, original.count)
        XCTAssertEqual(try rawSamples(result.data), try rawSamples(original))
        try assertImageIOEquivalent(original, result.data)
    }

    func testZopfliRunsAfterRepresentationReductionBringsImageUnderLimit() throws {
        let width = 600, height = 600
        var rows = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let firstColor = (x / (y % 11 + 1) + y / 11) % 2 == 0
                rows.append(contentsOf: firstColor ? [10, 20, 30, 255] : [50, 60, 70, 255])
            }
        }
        let original = try makePNG(width: width, height: height, color: 6, rows: rows)
        var options = OptimizationOptions(stripMetadata: false, recompress: false)
        options.pngZopfli = true
        XCTAssertEqual(Slimg.optimize(original, options: options).data, original, "Original filtered data exceeds Zopfli's work limit")
        options.pngZopfli = false; options.pngReduceRepresentation = true
        let reduced = Slimg.optimize(original, options: options)
        options.pngZopfli = true
        let result = Slimg.optimize(original, options: options)
        XCTAssertLessThan(result.optimizedSize, reduced.optimizedSize)
        XCTAssertEqual(result.savedBytes, result.report.bytesAccounted)
        XCTAssertTrue(result.report.items.contains { $0.label.contains("Zopfli") })
        let reducedHeader = try XCTUnwrap(payloads(reduced.data, "IHDR").first)
        let reducedLayout = try XCTUnwrap(PNGFiltering.Layout(reducedHeader))
        XCTAssertLessThan(reducedLayout.filteredSize, Zopfli.maximumSize)
        XCTAssertEqual(try rawSamples(reduced.data), try rawSamples(result.data))
        try assertImageIOEquivalent(reduced.data, result.data)
        print("PNG Zopfli after representation fixture: \(reduced.optimizedSize) -> \(result.optimizedSize) bytes")
    }
}
