import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SlimgCore

final class PNGReductionTests: XCTestCase {
    private let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private typealias Chunk = (String, [UInt8])

    private func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let n = data.count
        let body = Array(type.utf8) + data
        let crc = CRC32.checksum(body)
        return [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] + body +
            [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
    }
    private func integer(_ bytes: [UInt8], _ i: Int) -> Int {
        bytes[i..<i + 4].reduce(0) { $0 * 256 + Int($1) }
    }
    private func chunks(_ bytes: [UInt8]) -> [Chunk] {
        var offset = 8, result = [Chunk]()
        while offset + 12 <= bytes.count {
            let length = integer(bytes, offset)
            result.append((String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self), Array(bytes[offset + 8..<offset + 8 + length])))
            offset += 12 + length
        }
        return result
    }
    private func fixture(width: Int = 64, height: Int = 64, depth: Int = 8, type: Int,
                         samples: [UInt16], extra: [Chunk] = []) throws -> [UInt8] {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][type]!
        XCTAssertEqual(samples.count, width * height * channels)
        var header = [UInt8](repeating: 0, count: 13)
        for (offset, value) in [(0, width), (4, height)] {
            header[offset] = UInt8((value >> 24) & 255); header[offset + 1] = UInt8((value >> 16) & 255)
            header[offset + 2] = UInt8((value >> 8) & 255); header[offset + 3] = UInt8(value & 255)
        }
        header[8] = UInt8(depth); header[9] = UInt8(type)
        let rowBytes = (width * channels * depth + 7) / 8
        var raw = [UInt8](repeating: 0, count: height * (rowBytes + 1))
        for row in 0..<height {
            for x in 0..<width * channels {
                let s = samples[row * width * channels + x], base = row * (rowBytes + 1) + 1
                if depth == 16 { raw[base + x * 2] = UInt8(s >> 8); raw[base + x * 2 + 1] = UInt8(s & 255) }
                else if depth == 8 { raw[base + x] = UInt8(s) }
                else { raw[base + x * depth / 8] |= UInt8(s) << (8 - depth - x * depth % 8) }
            }
        }
        let compressed = try XCTUnwrap(Zlib.deflate(raw))
        return signature + chunk("IHDR", header) + extra.flatMap { chunk($0.0, $0.1) } + chunk("IDAT", compressed) + chunk("IEND", [])
    }

    /// Independent sample-level decoder for assertions. It expands samples to
    /// 16-bit RGBA and retains RGB even when alpha is zero; no premultiplication
    /// or CoreGraphics 8-bit drawing can conceal loss here.
    private func rgba16(_ png: [UInt8]) throws -> [UInt16] {
        let parts = chunks(png), h = parts[0].1
        let width = integer(h, 0), height = integer(h, 4), depth = Int(h[8]), type = Int(h[9])
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][type]!
        let rowBytes = (width * channels * depth + 7) / 8, bpp = max(1, (channels * depth + 7) / 8)
        let filtered = try XCTUnwrap(Zlib.inflate(parts.filter { $0.0 == "IDAT" }.flatMap { $0.1 }))
        var rows = [[UInt8]]()
        for y in 0..<height {
            let code = filtered[y * (rowBytes + 1)]
            var row = Array(filtered[y * (rowBytes + 1) + 1..<(y + 1) * (rowBytes + 1)])
            for x in 0..<rowBytes {
                let left = x >= bpp ? Int(row[x - bpp]) : 0
                let up = y > 0 ? Int(rows[y - 1][x]) : 0
                let corner = y > 0 && x >= bpp ? Int(rows[y - 1][x - bpp]) : 0
                var predictor = 0
                switch code {
                case 0: break
                case 1: predictor = left
                case 2: predictor = up
                case 3: predictor = (left + up) / 2
                case 4:
                    let p = left + up - corner, d = [abs(up - corner), abs(left - corner), abs(p - corner)]
                    predictor = d[0] <= d[1] && d[0] <= d[2] ? left : d[1] <= d[2] ? up : corner
                default: XCTFail("Invalid filter")
                }
                row[x] = UInt8((Int(row[x]) + predictor) & 255)
            }
            rows.append(row)
        }
        let palette = parts.first { $0.0 == "PLTE" }?.1 ?? []
        let trns = parts.first { $0.0 == "tRNS" }?.1 ?? []
        var result = [UInt16]()
        for row in rows {
            for x in 0..<width {
                var s = [UInt16]()
                for c in 0..<channels {
                    let sample = x * channels + c
                    if depth == 16 { s.append(UInt16(row[sample * 2]) * 256 + UInt16(row[sample * 2 + 1])) }
                    else if depth == 8 { s.append(UInt16(row[sample])) }
                    else { s.append(UInt16(row[sample * depth / 8] >> (8 - depth - sample * depth % 8) & UInt8((1 << depth) - 1))) }
                }
                let maxSample = (1 << depth) - 1
                func scale(_ value: UInt16) -> UInt16 { UInt16(Int(value) * 65535 / maxSample) }
                switch type {
                case 0: result += [scale(s[0]), scale(s[0]), scale(s[0]), trns.count == 2 && s[0] == UInt16(trns[0]) * 256 + UInt16(trns[1]) ? 0 : 65535]
                case 2:
                    var transparent = false
                    if trns.count == 6 {
                        let key = stride(from: 0, to: 6, by: 2).map { index -> UInt16 in
                            let high = UInt16(trns[index]) * 256
                            return high + UInt16(trns[index + 1])
                        }
                        transparent = s == key
                    }
                    result += [scale(s[0]), scale(s[1]), scale(s[2]), transparent ? 0 : 65535]
                case 3:
                    let index = Int(s[0])
                    result += [UInt16(palette[index * 3]) * 257, UInt16(palette[index * 3 + 1]) * 257,
                               UInt16(palette[index * 3 + 2]) * 257, UInt16(index < trns.count ? trns[index] : 255) * 257]
                case 4: result += [scale(s[0]), scale(s[0]), scale(s[0]), scale(s[1])]
                case 6: result += s.map(scale)
                default: XCTFail("Invalid type")
                }
            }
        }
        return result
    }
    private func noise(_ count: Int) -> [UInt16] {
        var seed: UInt32 = 0x23571234
        return (0..<count).map { _ in seed = seed &* 1664525 &+ 1013904223; return UInt16(seed >> 24) }
    }
    /// Complement the native sample decoder with independent ImageIO color
    /// interpretation. Native precision/hidden RGB remain checked separately.
    private func renderedRGBA(_ png: [UInt8]) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(png) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func assertExact(_ before: [UInt8], _ after: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertLessThan(after.count, before.count, file: file, line: line)
        XCTAssertEqual(try rgba16(before), try rgba16(after), file: file, line: line)
        XCTAssertEqual(try renderedRGBA(before), try renderedRGBA(after), file: file, line: line)
    }

    func testOpaqueAlphaRemovalPreservesEveryNativeSample() throws {
        let rgb = noise(64 * 64 * 3)
        var samples = [UInt16]()
        for i in stride(from: 0, to: rgb.count, by: 3) { samples += Array(rgb[i..<i + 3]) + [255] }
        let before = try fixture(type: 6, samples: samples)
        XCTAssertEqual(Slimg.optimize(Data(before)).data, Data(before), "Fixture is already compressed at the default level")
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        XCTAssertEqual(chunks(after)[0].1[9], 2)
        try assertExact(before, after)
        print("PNG reduction opaque alpha: \(before.count) -> \(after.count) bytes")
    }
    func testPaletteCreationKeepsHiddenColorsAndPartialAlpha() throws {
        let colors: [[UInt16]] = [[200, 17, 31, 0], [2, 88, 111, 0], [20, 30, 40, 128], [2, 3, 4, 255]]
        let pixels = noise(64 * 64).map { colors[Int($0) % 4] }.flatMap { $0 }
        let before = try fixture(type: 6, samples: pixels)
        XCTAssertEqual(Slimg.optimize(Data(before)).data, Data(before))
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        XCTAssertEqual(chunks(after)[0].1[9], 3); XCTAssertEqual(chunks(after)[0].1[8], 2)
        try assertExact(before, after)
        print("PNG reduction exact palette: \(before.count) -> \(after.count) bytes")
    }
    func testPaletteCompactionAndIndexDepth() throws {
        let colors = (0..<256).flatMap { [UInt8($0), UInt8(255 - $0), UInt8($0)] }
        let samples = noise(64 * 64).map { $0 % 2 }
        let before = try fixture(type: 3, samples: samples, extra: [("PLTE", colors), ("tRNS", [0, 128])])
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        XCTAssertEqual(chunks(after)[0].1[8], 1)
        XCTAssertEqual(chunks(after).first { $0.0 == "PLTE" }?.1.count, 6)
        try assertExact(before, after)
    }
    func testExact16To8PreservesNormalized16BitValues() throws {
        let before = try fixture(depth: 16, type: 2, samples: noise(64 * 64 * 3).map { $0 * 257 })
        XCTAssertEqual(Slimg.optimize(Data(before)).data, Data(before))
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        XCTAssertEqual(chunks(after)[0].1[8], 8)
        try assertExact(before, after)
        print("PNG reduction exact16->8: \(before.count) -> \(after.count) bytes")
    }
    func testInexact16BitAndHiddenSamplesAreNeverRounded() throws {
        var samples = noise(64 * 64 * 3).map { $0 * 257 }
        samples[0] = 12345
        let before = try fixture(depth: 16, type: 2, samples: samples)
        XCTAssertNil(PNGReduction.optimize(before))
        var rgba = [UInt16]()
        for i in stride(from: 0, to: samples.count, by: 3) { rgba += Array(samples[i..<i + 3]) + [0] }
        let transparent = try fixture(depth: 16, type: 6, samples: rgba)
        XCTAssertNil(PNGReduction.optimize(transparent))
    }
    func testExactGreyscaleReductionIncludingPackedOddRows() throws {
        let before = try fixture(width: 63, height: 61, type: 0, samples: noise(63 * 61).map { $0 % 2 * 255 })
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        XCTAssertEqual(chunks(after)[0].1[8], 1)
        try assertExact(before, after)
    }
    func testTransparencyKeyIsRemappedWithoutChangingHiddenRGB() throws {
        let colors: [[UInt16]] = [[20, 30, 40], [2, 3, 4], [5, 6, 7]]
        let before = try fixture(type: 2, samples: noise(64 * 64).map { colors[Int($0) % 3] }.flatMap { $0 },
                                 extra: [("tRNS", [0, 20, 0, 30, 0, 40])])
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        try assertExact(before, after)
    }
    func testColorProfilesAndOtherMetadataArePreservedExactly() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let profile = [UInt8](try XCTUnwrap(space.copyICCData()) as Data)
        let extras: [Chunk] = [("iCCP", Array("Profile\0\0".utf8) + (try XCTUnwrap(Zlib.deflate(profile)))),
                               ("gAMA", [0, 0, 177, 143]), ("pHYs", [0, 0, 11, 19, 0, 0, 11, 19, 1]),
                               ("tEXt", Array("Title\0Keep this".utf8)), ("vpAg", [1, 2, 3])]
        let before = try fixture(type: 6, samples: noise(64 * 64).flatMap { [$0, $0, $0, 255] }, extra: extras)
        let after = try XCTUnwrap(PNGReduction.optimize(before))
        for extra in extras { XCTAssertEqual(chunks(after).first { $0.0 == extra.0 }?.1, extra.1) }
        try assertExact(before, after)
    }
    func testSampleDependentAndUnsafeMetadataSkipReductions() throws {
        let samples = noise(64 * 64).flatMap { [$0, $0, $0, UInt16(255)] }
        for extra: Chunk in [("sBIT", [8, 8, 8, 8]), ("bKGD", [0, 1, 0, 2, 0, 3]),
                             ("hIST", [0, 1]), ("vpAG", [1]), ("acTL", [0, 0, 0, 1, 0, 0, 0, 0]),
                             ("cICP", [1, 13, 0, 1])] {
            XCTAssertNil(PNGReduction.optimize(try fixture(type: 6, samples: samples, extra: [extra])), extra.0)
        }
    }
    func testMoreThan256ColorsAreNotQuantized() throws {
        let random = noise(64 * 64 * 4)
        let before = try fixture(type: 6, samples: random)
        XCTAssertNil(PNGReduction.optimize(before))
    }
    func testOversizedDimensionsAndCriticalChunksAreRejected() throws {
        let original = try fixture(type: 6, samples: noise(64 * 64).flatMap { [$0, $0, $0, UInt16(255)] })
        var header = chunks(original)[0].1
        header[0] = 127; header[1] = 255; header[2] = 255; header[3] = 255
        let huge = signature + chunk("IHDR", header) + chunks(original).dropFirst().flatMap { chunk($0.0, $0.1) }
        XCTAssertNil(PNGReduction.optimize(huge))
        let unknown = try fixture(type: 6, samples: noise(64 * 64).flatMap { [$0, $0, $0, UInt16(255)] }, extra: [("ABCD", [1])])
        XCTAssertNil(PNGReduction.optimize(unknown))
    }
    func testMalformedTransparencyRangeAndOrderingAreRejected() throws {
        let samples = noise(64 * 64).flatMap { [$0, $0, $0] }
        let outOfRange = try fixture(type: 2, samples: samples,
                                    extra: [("tRNS", [1, 20, 0, 30, 0, 40])])
        XCTAssertNil(PNGReduction.optimize(outOfRange))
        let table: [UInt8] = [1, 2, 3, 4, 5, 6]
        let indexed = try fixture(type: 3, samples: noise(64 * 64).map { $0 % 2 },
                                  extra: [("tRNS", [0, 255]), ("PLTE", table)])
        XCTAssertNil(PNGReduction.optimize(indexed))
        let suggestedAfterTransparency = try fixture(type: 2, samples: samples,
                                                     extra: [("tRNS", [0, 20, 0, 30, 0, 40]), ("PLTE", table)])
        XCTAssertNil(PNGReduction.optimize(suggestedAfterTransparency))
        let excessAlpha = try fixture(type: 3, samples: noise(64 * 64).map { $0 % 2 },
                                      extra: [("PLTE", table), ("tRNS", [0, 255, 128])])
        XCTAssertNil(PNGReduction.optimize(excessAlpha))
    }
    func testMalformedAndInterlacedFilesAreLeftAlone() throws {
        let original = try fixture(type: 6, samples: noise(64 * 64).flatMap { [$0, $0, $0, UInt16(255)] })
        for count in [0, 8, 20, original.count - 1] { XCTAssertNil(PNGReduction.optimize(Array(original.prefix(count)))) }
        var badCRC = original; badCRC[30] ^= 1; XCTAssertNil(PNGReduction.optimize(badCRC))
        var h = chunks(original)[0].1; h[12] = 1
        let interlaced = signature + chunk("IHDR", h) + chunks(original).dropFirst().flatMap { chunk($0.0, $0.1) }
        XCTAssertNil(PNGReduction.optimize(interlaced))
        XCTAssertNil(PNGReduction.optimize(original + [1, 2, 3]))
    }
    func testAppOptionIsOffByDefaultAndNeverGrows() throws {
        XCTAssertFalse(OptimizationOptions().pngReduceRepresentation)
        let before = try fixture(type: 6, samples: noise(64 * 64).flatMap { [$0, $0, $0, UInt16(255)] })
        let disabled = Slimg.optimize(Data(before), options: .init(stripMetadata: false, recompress: false))
        XCTAssertEqual(disabled.data, Data(before))
        let enabled = Slimg.optimize(Data(before), options: .init(stripMetadata: false, recompress: false, pngReduceRepresentation: true))
        try assertExact(before, [UInt8](enabled.data))
        let again = Slimg.optimize(enabled.data, options: .init(stripMetadata: false, recompress: false, pngReduceRepresentation: true))
        XCTAssertLessThanOrEqual(again.optimizedSize, enabled.optimizedSize)
    }
}
