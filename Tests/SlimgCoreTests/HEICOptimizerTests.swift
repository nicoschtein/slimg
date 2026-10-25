import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlimgCore

final class HEICOptimizerTests: XCTestCase {
    private func encode(orientation: Int = 6, withMetadata: Bool = true, withDepth: Bool = false) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 23, height: 17))

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "tiff:Orientation" as CFString, orientation as CFNumber))
        if withMetadata {
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "exif:UserComment" as CFString,
                String(repeating: "Slimg iPhone photo metadata. ", count: 200) as CFString))
            XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary,
                kCGImagePropertyGPSLatitude, 37.7749 as CFNumber))
            XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary,
                kCGImagePropertyGPSLatitudeRef, "N" as CFString))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString,
                String(repeating: "Private XMP description. ", count: 100) as CFString))
            // Unknown namespaces may carry HDR/rendering information and must survive.
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata,
                "https://slimg.test/rendering/" as CFString, "render" as CFString, nil))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "render:Headroom" as CFString, "4" as CFString))
        }
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(context.makeImage()), metadata,
                                             [kCGImagePropertyOrientation: orientation] as CFDictionary)
        if withDepth {
            let values = (0..<32 * 24).map { Float32($0) / 768 }
            let depthData = values.withUnsafeBytes { Data($0) }
            CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, [
                kCGImageAuxiliaryDataInfoData: depthData,
                kCGImageAuxiliaryDataInfoDataDescription: [
                    kCGImagePropertyWidth: 32, kCGImagePropertyHeight: 24,
                    kCGImagePropertyBytesPerRow: 128,
                    kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat32,
                ],
                kCGImageAuxiliaryDataInfoMetadata: CGImageMetadataCreateMutable(),
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination), "HEIC test encoding failed")
        return output as Data
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func properties(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source(data), 0, nil)) as NSDictionary
    }

    func testStripsMetadataWithoutChangingPixelsOrientationOrColor() throws {
        let original = try encode()
        XCTAssertEqual(Slimg.detectFormat(original), .heic)
        let result = Slimg.optimize(original)
        XCTAssertEqual(result.format, .heic)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
        XCTAssertFalse(result.report.items.contains { $0.kind == .recompression })

        let beforeSource = try source(original)
        let afterSource = try source(result.data)
        XCTAssertEqual(CGImageSourceGetType(afterSource), UTType.heic.identifier as CFString)
        let before = try XCTUnwrap(CGImageSourceCreateImageAtIndex(beforeSource, 0, nil))
        let after = try XCTUnwrap(CGImageSourceCreateImageAtIndex(afterSource, 0, nil))
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(before.bitsPerComponent, after.bitsPerComponent)
        XCTAssertEqual(before.colorSpace?.copyICCData() as Data?, after.colorSpace?.copyICCData() as Data?)
        XCTAssertEqual(try XCTUnwrap(before.dataProvider?.data) as Data,
                       try XCTUnwrap(after.dataProvider?.data) as Data)

        let beforeProperties = try properties(original)
        let afterProperties = try properties(result.data)
        XCTAssertEqual(beforeProperties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNotNil(beforeProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(afterProperties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(afterProperties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(afterProperties[kCGImagePropertyProfileName] as? String, "Display P3")
        let exif = afterProperties[kCGImagePropertyExifDictionary] as? NSDictionary
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])

        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(afterSource, 0, nil))
        XCTAssertNil(CGImageMetadataCopyTagWithPath(metadata, nil, "dc:description" as CFString))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "render:Headroom" as CFString) as String?, "4")
        XCTAssertFalse(Slimg.optimize(result.data).changed, "Repeated runs must be stable")
    }

    func testAllOrientationsSurvive() throws {
        for orientation in 1...8 {
            let original = try encode(orientation: orientation)
            XCTAssertEqual(try properties(original)[kCGImagePropertyOrientation] as? Int, orientation)
            let result = Slimg.optimize(original)
            XCTAssertTrue(result.changed)
            XCTAssertEqual(try properties(result.data)[kCGImagePropertyOrientation] as? Int, orientation)
        }
    }

    func testKeepMetadataLeavesOriginalUntouched() throws {
        let original = try encode()
        for keepColorProfile in [true, false] {
            let result = Slimg.optimize(original, options: .init(stripMetadata: false, keepColorProfile: keepColorProfile))
            XCTAssertEqual(result.data, original)
            XCTAssertTrue(result.report.isEmpty)
        }
    }

    func testNoRecompressStillStripsHEICMetadata() throws {
        let result = Slimg.optimize(try encode(), options: .init(recompress: false))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.report.bytesAccounted, result.savedBytes)
    }

    func testPortraitDepthIsPreserved() throws {
        let original = try encode(withDepth: true)
        let result = Slimg.optimize(original)
        XCTAssertTrue(result.changed)
        let before = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source(original), 0, kCGImageAuxiliaryDataTypeDisparity)) as NSDictionary
        let after = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source(result.data), 0, kCGImageAuxiliaryDataTypeDisparity)) as NSDictionary
        XCTAssertEqual(before[kCGImageAuxiliaryDataInfoData] as? Data, after[kCGImageAuxiliaryDataInfoData] as? Data)
        XCTAssertEqual(before[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary,
                       after[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary)
    }

    func testStripColorKeepsHEICProfile() throws {
        let original = try encode()
        let result = Slimg.optimize(original, options: .init(keepColorProfile: false))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(try properties(result.data)[kCGImagePropertyProfileName] as? String, "Display P3")
    }

    func testMetadataFreeFileNeverGrows() throws {
        let original = try encode(withMetadata: false)
        let result = Slimg.optimize(original)
        XCTAssertLessThanOrEqual(result.optimizedSize, original.count)
        if !result.changed { XCTAssertEqual(result.data, original) }
    }

    func testBrandDetection() {
        func ftyp(_ major: String, _ compatible: String) -> Data {
            Data([0, 0, 0, 20] + Array("ftyp\(major)".utf8) + [0, 0, 0, 0] + Array(compatible.utf8))
        }
        XCTAssertEqual(Slimg.detectFormat(ftyp("heic", "mif1")), .heic)
        XCTAssertEqual(Slimg.detectFormat(ftyp("mif1", "heic")), .heic)
        XCTAssertEqual(Slimg.detectFormat(ftyp("heix", "mif1")), .heic)
        XCTAssertEqual(Slimg.detectFormat(ftyp("avif", "mif1")), .unknown)
        XCTAssertEqual(Slimg.detectFormat(ftyp("mif1", "mif1")), .unknown)
        let truncated = ftyp("heic", "mif1").dropLast()
        XCTAssertEqual(Slimg.detectFormat(Data(truncated)), .unknown)
        let extended = Data([0, 0, 0, 1] + Array("ftyp".utf8) + [0, 0, 0, 0, 0, 0, 0, 24]
                            + Array("heic".utf8) + [0, 0, 0, 0])
        XCTAssertEqual(Slimg.detectFormat(extended), .heic)
        let oversized = Data([0, 0, 0, 1] + Array("ftyp".utf8) + [UInt8](repeating: 255, count: 8))
        XCTAssertEqual(Slimg.detectFormat(oversized), .unknown)
    }

    func testMalformedHEICIsUntouched() throws {
        let original = try encode()
        for count in [0, 8, 16, 32, original.count / 2] {
            let truncated = Data(original.prefix(count))
            let result = Slimg.optimize(truncated)
            XCTAssertEqual(result.data, truncated)
            XCTAssertTrue(result.report.isEmpty)
        }
        let fake = Data([0, 0, 0, 16] + Array("ftypheic".utf8) + [0, 0, 0, 0])
        XCTAssertEqual(Slimg.detectFormat(fake), .heic)
        XCTAssertEqual(Slimg.optimize(fake).data, fake)
    }
}
