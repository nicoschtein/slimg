/// Lossless GIF optimization: drops Comment Extensions and non-essential
/// Application Extensions (e.g. XMP metadata) while preserving the NETSCAPE
/// looping extension, all graphic control extensions, color tables and the
/// LZW-compressed image data. Pixels and animation timing are untouched.
///
/// On any structural surprise it bails out (returns nil) so the caller keeps
/// the original bytes — we never risk corrupting a file we don't fully parse.
enum GIFOptimizer {
    static func optimize(_ d: [UInt8], options: OptimizationOptions) -> OptimizerOutput? {
        guard options.stripMetadata else { return nil }
        let n = d.count
        guard n > 13, d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(n)
        var items = [RemovedItem]()

        // Header (6) + Logical Screen Descriptor (7).
        out.append(contentsOf: d[0..<13])
        let packed = d[10]
        var i = 13

        // Global Color Table.
        if packed & 0x80 != 0 {
            let size = 3 * (1 << ((Int(packed) & 0x07) + 1))
            guard i + size <= n else { return nil }
            out.append(contentsOf: d[i..<i + size])
            i += size
        }

        while i < n {
            let b = d[i]

            if b == 0x3B { // trailer
                out.append(0x3B)
                i += 1
                break
            }

            if b == 0x2C { // image descriptor
                guard i + 10 <= n else { return nil }
                let imgPacked = d[i + 9]
                let start = i
                i += 10
                if imgPacked & 0x80 != 0 { // local color table
                    let size = 3 * (1 << ((Int(imgPacked) & 0x07) + 1))
                    guard i + size <= n else { return nil }
                    i += size
                }
                guard i < n else { return nil }
                i += 1 // LZW minimum code size
                guard let after = skipSubBlocks(d, i) else { return nil }
                i = after
                out.append(contentsOf: d[start..<i]) // image data is always kept
                continue
            }

            if b == 0x21 { // extension
                guard i + 1 < n else { return nil }
                let label = d[i + 1]
                let start = i
                let blocksStart = i + 2
                guard let after = skipSubBlocks(d, blocksStart) else { return nil }

                switch label {
                case 0xFE: // comment — drop
                    items.append(RemovedItem(kind: .comment, label: "Comment extension", bytes: after - start))
                case 0xFF: // application extension — keep only NETSCAPE (looping)
                    if isLoopingExtension(d, at: blocksStart, end: n) {
                        out.append(contentsOf: d[start..<after])
                    } else {
                        let isXMP = isApplicationID(d, at: blocksStart, end: n, id: "XMP Data")
                        items.append(RemovedItem(
                            kind: isXMP ? .xmp : .appData,
                            label: isXMP ? "XMP metadata extension" : "Application metadata extension",
                            bytes: after - start
                        ))
                    }
                default: // graphic control (0xF9), plain text (0x01), unknown — keep
                    out.append(contentsOf: d[start..<after])
                }
                i = after
                continue
            }

            return nil // unrecognized block; don't risk corruption
        }

        return OptimizerOutput(bytes: out, items: items)
    }

    /// Skip a chain of GIF data sub-blocks starting at a size byte; returns the
    /// index just past the terminating zero-length block.
    private static func skipSubBlocks(_ d: [UInt8], _ start: Int) -> Int? {
        var i = start
        let n = d.count
        while i < n {
            let size = Int(d[i])
            i += 1
            if size == 0 { return i }
            i += size
            if i > n { return nil }
        }
        return nil
    }

    private static let netscape: [UInt8] = Array("NETSCAPE".utf8)

    private static func isLoopingExtension(_ d: [UInt8], at blocksStart: Int, end n: Int) -> Bool {
        isApplicationID(d, at: blocksStart, end: n, idBytes: netscape)
    }

    private static func isApplicationID(_ d: [UInt8], at blocksStart: Int, end n: Int, id: String) -> Bool {
        isApplicationID(d, at: blocksStart, end: n, idBytes: Array(id.utf8))
    }

    private static func isApplicationID(_ d: [UInt8], at blocksStart: Int, end n: Int, idBytes: [UInt8]) -> Bool {
        guard blocksStart < n else { return false }
        let idSize = Int(d[blocksStart])
        let idStart = blocksStart + 1
        guard idSize >= idBytes.count, idStart + idBytes.count <= n else { return false }
        for k in 0..<idBytes.count where d[idStart + k] != idBytes[k] {
            return false
        }
        return true
    }
}
