import Foundation

/// Builds EXIF APP1 segments for tests: a TIFF structure with IFD0 and any
/// sub-IFDs, laid out in order, each IFD followed by its out-of-line values.
struct EXIFBuilder {
    enum Value {
        /// Raw value bytes in the builder's byte order: up to 4 are stored inline.
        case bytes([UInt8])
        /// Offset of another IFD in `ifds`, written as a LONG pointer.
        case ifd(Int)
    }

    struct Entry {
        let tag: UInt16, type: UInt16, count: UInt32, value: Value
    }

    let bigEndian: Bool
    /// IFD0 first; sub-IFDs referenced through `.ifd(index)` entries.
    var ifds: [[Entry]]

    func u16(_ value: UInt16) -> [UInt8] {
        bigEndian ? [UInt8(value >> 8), UInt8(value & 255)] : [UInt8(value & 255), UInt8(value >> 8)]
    }

    func u32(_ value: UInt32) -> [UInt8] {
        let high = u16(UInt16(value >> 16)), low = u16(UInt16(value & 0xFFFF))
        return bigEndian ? high + low : low + high
    }

    // MARK: Entry helpers

    func short(_ tag: UInt16, _ value: UInt16) -> Entry {
        Entry(tag: tag, type: 3, count: 1, value: .bytes(u16(value) + [0, 0]))
    }

    func ascii(_ tag: UInt16, _ text: String) -> Entry {
        let bytes = Array(text.utf8) + [0]
        return Entry(tag: tag, type: 2, count: UInt32(bytes.count), value: .bytes(bytes))
    }

    func undefined(_ tag: UInt16, _ bytes: [UInt8]) -> Entry {
        Entry(tag: tag, type: 7, count: UInt32(bytes.count), value: .bytes(bytes))
    }

    func pointer(_ tag: UInt16, to ifd: Int) -> Entry {
        Entry(tag: tag, type: 4, count: 1, value: .ifd(ifd))
    }

    // MARK: Layout

    private func outOfLineSize(_ entries: [Entry]) -> Int {
        entries.reduce(0) { total, entry in
            guard case let .bytes(bytes) = entry.value, bytes.count > 4 else { return total }
            return total + (bytes.count + 1) / 2 * 2 // keep offsets word-aligned
        }
    }

    /// The TIFF structure, starting with the byte-order mark.
    func tiff() -> [UInt8] {
        var offsets = [Int]()
        var next = 8
        for entries in ifds {
            offsets.append(next)
            next += 2 + entries.count * 12 + 4 + outOfLineSize(entries)
        }
        var out: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        out += u16(42)
        out += u32(8)
        for (index, entries) in ifds.enumerated() {
            var data = [UInt8]()
            let dataStart = offsets[index] + 2 + entries.count * 12 + 4
            out += u16(UInt16(entries.count))
            for entry in entries {
                out += u16(entry.tag)
                out += u16(entry.type)
                out += u32(entry.count)
                switch entry.value {
                case let .ifd(target):
                    out += u32(UInt32(offsets[target]))
                case let .bytes(bytes) where bytes.count <= 4:
                    out += bytes + [UInt8](repeating: 0, count: 4 - bytes.count)
                case let .bytes(bytes):
                    out += u32(UInt32(dataStart + data.count))
                    data += bytes
                    if data.count % 2 == 1 { data.append(0) }
                }
            }
            out += u32(0) // no next IFD
            out += data
        }
        return out
    }

    /// A complete APP1 segment: marker, length, "Exif\0\0" and the TIFF structure.
    func segment() -> [UInt8] {
        let payload = Array("Exif\0\0".utf8) + tiff()
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 255)] + payload
    }

    /// A camera-style EXIF block: IFD0 with Make, Model and optional Orientation;
    /// an Exif IFD with ExifVersion, ColorSpace, a bulky MakerNote-like comment
    /// and an optional Interoperability IFD carrying `interopIndex`.
    static func camera(bigEndian: Bool, orientation: UInt16? = nil, colorSpace: UInt16? = nil,
                       interopIndex: String? = nil) -> EXIFBuilder {
        var builder = EXIFBuilder(bigEndian: bigEndian, ifds: [])
        var ifd0 = [builder.ascii(0x010F, "Slimg Camera"), builder.ascii(0x0110, "Test Model")]
        if let orientation { ifd0.append(builder.short(0x0112, orientation)) }
        ifd0.append(builder.pointer(0x8769, to: 1))
        var exif = [builder.undefined(0x9000, Array("0230".utf8))]
        exif.append(builder.undefined(0x9286, [UInt8](repeating: 0x41, count: 300))) // UserComment
        if let colorSpace { exif.append(builder.short(0xA001, colorSpace)) }
        var ifds = [ifd0, exif]
        if let interopIndex {
            ifds[1].append(builder.pointer(0xA005, to: 2))
            ifds.append([builder.ascii(0x0001, interopIndex), builder.undefined(0x0002, Array("0100".utf8))])
        }
        builder.ifds = ifds
        return builder
    }
}
