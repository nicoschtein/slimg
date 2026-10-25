import Foundation
import ImageIO

/// Uses ImageIO's compressed-data copy operation, never a decode/re-encode.
/// HEIC color profiles and rendering metadata are always retained, even when
/// keepColorProfile is false: stripping them is not supported by this path.
enum HEICOptimizer {
    /// HEIF is also used for AVIF and other codecs. Require an HEVC image brand,
    /// not just the generic mif1 brand or a filename extension.
    static func isHEIC(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 16, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }
        var size = bytes[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var headerSize = 8
        if size == 1 {
            size = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            headerSize = 16
        } else if size == 0 {
            size = UInt64(data.count)
        }
        guard size >= UInt64(headerSize + 8), size <= UInt64(data.count),
              (size - UInt64(headerSize)) % 4 == 0 else { return false }
        let brands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs"]
        let ftyp = [UInt8](data.prefix(Int(size)))
        for offset in stride(from: headerSize, to: Int(size), by: 4) {
            if offset == headerSize + 4 { continue } // minor version, not a brand
            if brands.contains(String(decoding: ftyp[offset..<offset + 4], as: UTF8.self)) { return true }
        }
        return false
    }

    static func optimize(_ data: Data, options: OptimizationOptions) -> OptimizerOutput? {
        guard options.stripMetadata,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let sourceMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(sourceMetadata) else { return nil }

        // Keep unfamiliar namespaces: iPhone HDR/gain-map and auxiliary image
        // metadata can affect rendering. Only strip known descriptive tags.
        let descriptiveNamespaces: Set<String> = [
            "http://ns.adobe.com/tiff/1.0/",
            "http://ns.adobe.com/exif/1.0/",
            "http://cipa.jp/exif/1.0/",
            "http://ns.adobe.com/exif/1.0/aux/",
            "http://ns.adobe.com/photoshop/1.0/",
            "http://ns.adobe.com/xap/1.0/",
            "http://ns.adobe.com/xap/1.0/mm/",
            "http://purl.org/dc/elements/1.1/",
            "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
            "http://iptc.org/std/Iptc4xmpExt/2008-02-29/",
        ]
        var paths = [CFString]()
        CGImageMetadataEnumerateTagsUsingBlock(sourceMetadata, nil, nil) { path, tag in
            if let namespace = CGImageMetadataTagCopyNamespace(tag),
               descriptiveNamespaces.contains(namespace as String) {
                paths.append(path)
            }
            return true
        }
        for path in paths {
            // ImageIO can enumerate unresolvable EXIF paths (for example,
            // exifEX:CompositeImage in iPhone photos), or aliases whose target
            // was already removed. Neither should abort the whole operation.
            guard CGImageMetadataCopyTagWithPath(metadata, nil, path) != nil else { continue }
            guard CGImageMetadataRemoveTagWithPath(metadata, nil, path) else { return nil }
        }

        // Orientation is descriptive in EXIF but essential to how a photo looks.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber {
            guard CGImageMetadataSetValueWithPath(metadata, nil, "tiff:Orientation" as CFString, orientation) else {
                return nil
            }
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let copyOptions: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        // This call writes the destination itself; do not call Finalize or fall
        // back to AddImageFromSource (which could re-encode the HEVC payload).
        guard CGImageDestinationCopyImageSource(destination, source, copyOptions as CFDictionary, nil),
              output.length < data.count else { return nil }
        return OptimizerOutput(bytes: [UInt8](output as Data), items: [
            RemovedItem(kind: .other, label: "HEIC metadata and container overhead", bytes: data.count - output.length),
        ])
    }
}
