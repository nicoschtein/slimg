import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

/// Cameras shooting in Adobe RGB often embed no ICC profile and mark the color
/// space only in EXIF (ColorSpace Uncalibrated + InteroperabilityIndex "R03").
/// Stripping EXIF must not change how such a photo's colors are rendered.
final class JPEGColorSpaceTests: XCTestCase, JPEGFixtures {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let removedLabel = "EXIF metadata (APP1)"
    private let colorLabel = "EXIF metadata (APP1), color space kept"
    private let bothLabel = "EXIF metadata (APP1), orientation and color space kept"

    /// An ImageIO JPEG with no metadata and no embedded ICC profile.
    private func baseJPEG() -> [UInt8] {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, makeCGImage(), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let stripped = [UInt8](Slimg.optimize(output as Data, options: .init(keepColorProfile: false)).data)
        XCTAssertNil(range(of: Array("ICC_PROFILE".utf8), in: stripped))
        XCTAssertNil(range(of: Array("Exif\0\0".utf8), in: stripped))
        return stripped
    }

    private func adobeRGBSegment(bigEndian: Bool, orientation: UInt16? = nil) -> [UInt8] {
        EXIFBuilder.camera(bigEndian: bigEndian, orientation: orientation, colorSpace: 0xFFFF,
                           interopIndex: "R03").segment()
    }

    private func iccSegment(_ name: CFString) throws -> [UInt8] {
        let profile = try XCTUnwrap(CGColorSpace(name: name)?.copyICCData() as Data?)
        return segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1] + [UInt8](profile))
    }

    /// Same rendered colors and the same decoded color space.
    private func assertSameColors(_ original: [UInt8], _ optimized: [UInt8],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try pixels(Data(original), in: sRGB), try pixels(Data(optimized), in: sRGB),
                       "rendered colors must be unchanged", file: file, line: line)
        let before = try decodedImage(Data(original)).colorSpace
        let after = try decodedImage(Data(optimized)).colorSpace
        XCTAssertEqual(before?.name as String?, after?.name as String?, file: file, line: line)
        XCTAssertEqual(before?.copyICCData() as Data?, after?.copyICCData() as Data?, file: file, line: line)
    }

    // MARK: - Premise

    /// The fix only matters if ImageIO honors the EXIF marker. If this fails,
    /// ImageIO ignores R03 and keeping it is unnecessary.
    func testImageIORendersEXIFAdobeRGBMarkerDifferently() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            let tagged = inserting(adobeRGBSegment(bigEndian: bigEndian), into: base)
            XCTAssertNotEqual(try pixels(Data(tagged), in: sRGB), try pixels(Data(base), in: sRGB),
                              "ImageIO should render an R03-tagged JPEG as Adobe RGB, not sRGB")
        }
    }

    // MARK: - Color space kept

    func testAdobeRGBMarkerSurvivesDefaultOptimization() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            let exif = adobeRGBSegment(bigEndian: bigEndian)
            let input = inserting(exif, into: base)
            let result = Slimg.optimize(Data(input))
            let minimal = JPEGOptimizer.minimalEXIF(.init(bigEndian: bigEndian, orientation: nil, adobeRGB: .dcf))
            let output = [UInt8](result.data)

            XCTAssertEqual(output, inserting(minimal, into: base))
            XCTAssertNil(range(of: Array("Slimg Camera".utf8), in: output), "camera make must be stripped")
            try assertSameColors(input, output)
            XCTAssertEqual(result.report.items.count, 1)
            XCTAssertEqual(result.report.items.first?.kind, .exif)
            XCTAssertEqual(result.report.items.first?.label, colorLabel)
            XCTAssertEqual(result.report.items.first?.bytes, exif.count - minimal.count)
            XCTAssertEqual(result.savedBytes, exif.count - minimal.count)
        }
    }

    func testOrientationAndAdobeRGBAreKeptTogether() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            let input = inserting(adobeRGBSegment(bigEndian: bigEndian, orientation: 6), into: base)
            XCTAssertEqual(try orientation(Data(input)), 6)
            var options = OptimizationOptions()
            options.jpegOptimizeHuffman = true
            for options in [OptimizationOptions(), options] {
                let result = Slimg.optimize(Data(input), options: options)
                XCTAssertTrue(result.changed)
                XCTAssertEqual(try orientation(result.data), 6)
                try assertSameColors(input, [UInt8](result.data))
                XCTAssertEqual(result.report.items.first { $0.kind == .exif }?.label, bothLabel)
                XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
            }
        }
    }

    func testMinimalColorSegmentLayout() {
        var little: [UInt8] = [0xFF, 0xE1, 0x00, 0x52]
        little += Array("Exif\0\0".utf8)
        little += [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]             // header, IFD0 at 8
        little += [0x01, 0x00]                                                 // IFD0: one entry
        little += [0x69, 0x87, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A, 0x00, 0x00, 0x00] // Exif IFD at 26
        little += [0x00, 0x00, 0x00, 0x00]
        little += [0x02, 0x00]                                                 // Exif IFD: two entries
        little += [0x01, 0xA0, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00] // Uncalibrated
        little += [0x05, 0xA0, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00] // Interop at 56
        little += [0x00, 0x00, 0x00, 0x00]
        little += [0x01, 0x00]                                                 // Interop IFD: one entry
        little += [0x01, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x52, 0x30, 0x33, 0x00] // "R03"
        little += [0x00, 0x00, 0x00, 0x00]
        let essentials = JPEGOptimizer.EXIFEssentials(bigEndian: false, orientation: nil, adobeRGB: .dcf)
        XCTAssertEqual(JPEGOptimizer.minimalEXIF(essentials), little)

        var big: [UInt8] = [0xFF, 0xE1, 0x00, 0x52]
        big += Array("Exif\0\0".utf8)
        big += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        big += [0x00, 0x01]
        big += [0x87, 0x69, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A]
        big += [0x00, 0x00, 0x00, 0x00]
        big += [0x00, 0x02]
        big += [0xA0, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0x00, 0x00]
        big += [0xA0, 0x05, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38]
        big += [0x00, 0x00, 0x00, 0x00]
        big += [0x00, 0x01]
        big += [0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x52, 0x30, 0x33, 0x00]
        big += [0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(JPEGOptimizer.minimalEXIF(.init(bigEndian: true, orientation: nil, adobeRGB: .dcf)), big)

        // Every minimal segment reads back as what it was built from.
        for bigEndian in [false, true] {
            for orientation: UInt16? in [nil, 6] {
                let markers: [JPEGOptimizer.AdobeRGBMarker?] = [nil, .dcf, .init(colorSpace: 1), .init(colorSpace: nil)]
                for adobeRGB in markers where orientation != nil || adobeRGB != nil {
                    let essentials = JPEGOptimizer.EXIFEssentials(bigEndian: bigEndian, orientation: orientation,
                                                                  adobeRGB: adobeRGB)
                    let segment = JPEGOptimizer.minimalEXIF(essentials)
                    XCTAssertEqual(JPEGOptimizer.readEXIF(segment, tiffStart: 10, end: segment.count, colorSpace: true),
                                   essentials)
                }
            }
        }
    }

    // MARK: - Marker not needed: dropped as before

    func testEmbeddedProfileMakesMarkerRedundant() throws {
        let base = baseJPEG()
        let icc = try iccSegment(CGColorSpace.adobeRGB1998)
        let withProfile = inserting(icc, into: base)
        for bigEndian in [false, true] {
            let input = inserting(adobeRGBSegment(bigEndian: bigEndian), into: withProfile)
            let result = Slimg.optimize(Data(input))
            XCTAssertEqual([UInt8](result.data), withProfile, "EXIF dropped whole, profile kept")
            XCTAssertEqual(result.report.items.map(\.label), [removedLabel])
            try assertSameColors(input, [UInt8](result.data))
        }
    }

    func testStripColorDropsMarker() {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            let exif = adobeRGBSegment(bigEndian: bigEndian)
            let result = Slimg.optimize(Data(inserting(exif, into: base)), options: .init(keepColorProfile: false))
            XCTAssertEqual([UInt8](result.data), base)
            XCTAssertEqual(result.report.items.map(\.label), [removedLabel])
            XCTAssertEqual(result.report.items.first?.bytes, exif.count)
        }
    }

    /// R03 is kept with whatever ColorSpace accompanies it, so the pair reads
    /// the same whichever of the two a viewer consults.
    func testNonStandardR03PairingsAreKeptAsFound() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            for colorSpace: UInt16? in [1, nil] {
                let exif = EXIFBuilder.camera(bigEndian: bigEndian, colorSpace: colorSpace, interopIndex: "R03").segment()
                let input = inserting(exif, into: base)
                let result = Slimg.optimize(Data(input))
                let marker = JPEGOptimizer.AdobeRGBMarker(colorSpace: colorSpace)
                let minimal = JPEGOptimizer.minimalEXIF(.init(bigEndian: bigEndian, orientation: nil, adobeRGB: marker))
                XCTAssertEqual([UInt8](result.data), inserting(minimal, into: base), "\(String(describing: colorSpace))")
                XCTAssertEqual(result.report.items.map(\.label), [colorLabel])
                try assertSameColors(input, [UInt8](result.data))
            }
        }
    }

    func testSRGBAndIncompleteMarkersAreDroppedAsBefore() throws {
        let base = baseJPEG()
        let variants: [(colorSpace: UInt16?, index: String?)] = [
            (1, "R98"), (0xFFFF, "R98"), (0xFFFF, "THM"), (0xFFFF, nil), (nil, nil),
        ]
        for bigEndian in [false, true] {
            for variant in variants {
                let exif = EXIFBuilder.camera(bigEndian: bigEndian, colorSpace: variant.colorSpace,
                                              interopIndex: variant.index).segment()
                let input = inserting(exif, into: base)
                let result = Slimg.optimize(Data(input))
                XCTAssertEqual([UInt8](result.data), base, "\(variant)")
                XCTAssertEqual(result.report.items.map(\.label), [removedLabel], "\(variant)")
                try assertSameColors(input, [UInt8](result.data))
            }
        }
    }

    // MARK: - Layout variants that still read unambiguously

    /// Sub-IFD pointers of type IFD (13), a 3-byte "R03" index without NUL, and
    /// an Interop IFD missing its (irrelevant) next-IFD offset all carry the
    /// marker as clearly as the standard layout.
    func testEquivalentLayoutsKeepTheMarker() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            let builder = EXIFBuilder.camera(bigEndian: bigEndian, colorSpace: 0xFFFF, interopIndex: "R03")
            var ifdPointers = builder
            ifdPointers.ifds[0][2] = EXIFBuilder.Entry(tag: 0x8769, type: 13, count: 1, value: .ifd(1))
            ifdPointers.ifds[1][3] = EXIFBuilder.Entry(tag: 0xA005, type: 13, count: 1, value: .ifd(2))
            var shortIndex = builder
            shortIndex.ifds[2][0] = EXIFBuilder.Entry(tag: 0x0001, type: 2, count: 3, value: .bytes(Array("R03".utf8)))
            // The Interop IFD is last and has no out-of-line data: drop its next-IFD offset.
            var unterminated = Array(builder.segment().dropLast(4))
            unterminated[2] = UInt8((unterminated.count - 2) >> 8)
            unterminated[3] = UInt8((unterminated.count - 2) & 255)

            let minimal = JPEGOptimizer.minimalEXIF(.init(bigEndian: bigEndian, orientation: nil, adobeRGB: .dcf))
            for (name, exif) in [("IFD pointers", ifdPointers.segment()), ("3-byte index", shortIndex.segment()),
                                 ("unterminated Interop IFD", unterminated)] {
                let input = inserting(exif, into: base)
                let result = Slimg.optimize(Data(input))
                XCTAssertEqual([UInt8](result.data), inserting(minimal, into: base), name)
                XCTAssertEqual(result.report.items.map(\.label), [colorLabel], name)
                try assertSameColors(input, [UInt8](result.data))
            }
        }
    }

    /// A sub-IFD pointer leading past the end of the EXIF data can't be followed
    /// by any reader, so it can't carry the marker: EXIF is reduced as usual.
    func testUnreachableSubIFDsCarryNoMarker() throws {
        let base = baseJPEG()
        for bigEndian in [false, true] {
            for orientation: UInt16? in [nil, 6] {
                let builder = EXIFBuilder.camera(bigEndian: bigEndian, orientation: orientation, colorSpace: 0xFFFF,
                                                 interopIndex: "R03")
                let exifPointer = builder.ifds[0].firstIndex { $0.tag == 0x8769 }!
                var farExif = builder
                farExif.ifds[0][exifPointer] = EXIFBuilder.Entry(tag: 0x8769, type: 4, count: 1,
                                                                 value: .bytes(builder.u32(5000)))
                var farInterop = builder
                farInterop.ifds[1][3] = EXIFBuilder.Entry(tag: 0xA005, type: 4, count: 1,
                                                          value: .bytes(builder.u32(0xFFFF_FFF0)))
                let expected = orientation.map {
                    inserting(JPEGOptimizer.minimalEXIF(orientation: $0, bigEndian: bigEndian), into: base)
                } ?? base
                for (name, exif) in [("Exif IFD", farExif.segment()), ("Interop IFD", farInterop.segment())] {
                    let input = inserting(exif, into: base)
                    let result = Slimg.optimize(Data(input))
                    XCTAssertEqual([UInt8](result.data), expected, "\(name), orientation \(String(describing: orientation))")
                    try assertSameColors(input, [UInt8](result.data))
                }
            }
        }
    }

    /// A broken ICC chunk is no profile: decoders fall back to the EXIF marker.
    func testTruncatedICCChunkDoesNotReplaceMarker() throws {
        let base = baseJPEG()
        let brokenICC = segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1] + [UInt8](repeating: 0, count: 16))
        let withBroken = inserting(brokenICC, into: base)
        let input = inserting(adobeRGBSegment(bigEndian: true), into: withBroken)
        let result = Slimg.optimize(Data(input))
        let minimal = JPEGOptimizer.minimalEXIF(.init(bigEndian: true, orientation: nil, adobeRGB: .dcf))
        XCTAssertEqual([UInt8](result.data), inserting(minimal, into: withBroken))
        try assertSameColors(input, [UInt8](result.data))
    }

    // MARK: - Malformed color structures are kept verbatim

    func testMalformedColorStructuresAreLeftUnchanged() throws {
        let base = baseJPEG()
        let note = comment("strip me")
        let builder = EXIFBuilder.camera(bigEndian: false, colorSpace: 0xFFFF, interopIndex: "R03")
        // IFD0: Make, Model, Exif pointer. Exif IFD: ExifVersion, UserComment,
        // ColorSpace, Interop pointer. Interop IFD: index, version.
        func variant(_ change: (inout EXIFBuilder) -> Void) -> [UInt8] {
            var copy = builder
            change(&copy)
            return copy.segment()
        }
        let truncated: [UInt8] = {
            let full = builder.segment()
            var cut = Array(full[0..<(full.count - 20)]) // ends inside the Interop IFD
            cut[2] = UInt8((cut.count - 2) >> 8)
            cut[3] = UInt8((cut.count - 2) & 255)
            return cut
        }()
        let cases: [(String, [UInt8])] = [
            ("truncated Interop IFD", truncated),
            ("duplicate ColorSpace", variant { $0.ifds[1].append($0.short(0xA001, 0xFFFF)) }),
            ("ColorSpace not SHORT", variant {
                $0.ifds[1][2] = EXIFBuilder.Entry(tag: 0xA001, type: 4, count: 1, value: .bytes($0.u32(0xFFFF)))
            }),
            ("Exif pointer into the TIFF header", variant {
                $0.ifds[0][2] = EXIFBuilder.Entry(tag: 0x8769, type: 4, count: 1, value: .bytes($0.u32(4)))
            }),
            ("Interop pointer not LONG", variant {
                $0.ifds[1][3] = EXIFBuilder.Entry(tag: 0xA005, type: 3, count: 1, value: .bytes($0.u16(60) + [0, 0]))
            }),
            ("Interop index not ASCII", variant {
                $0.ifds[2][0] = EXIFBuilder.Entry(tag: 0x0001, type: 7, count: 4, value: .bytes(Array("R03\0".utf8)))
            }),
        ]
        for (name, exif) in cases {
            XCTAssertNil(JPEGOptimizer.readEXIF(exif, tiffStart: 10, end: exif.count, colorSpace: true), name)
            let input = inserting(exif + note, into: base)
            let kept = Slimg.optimize(Data(input))
            XCTAssertEqual([UInt8](kept.data), inserting(exif, into: base), "\(name): EXIF kept verbatim")
            XCTAssertEqual(kept.report.items.map(\.kind), [.comment], name)

            // The color structures are not read when color profiles are stripped.
            let stripped = Slimg.optimize(Data(input), options: .init(keepColorProfile: false))
            XCTAssertEqual([UInt8](stripped.data), base, name)
        }
    }
}
