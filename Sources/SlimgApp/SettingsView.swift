import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: OptimizerModel

    var body: some View {
        Form {
            Section("What to remove") {
                Toggle("Strip metadata (EXIF, XMP, IPTC, comments)", isOn: $model.stripMetadata)
                Toggle("Strip color profiles (ICC)", isOn: Binding(
                    get: { !model.keepColorProfile },
                    set: { model.keepColorProfile = !$0 }
                ))
                .help("Removing color profiles can shift how colors appear. Off by default. HEIC color profiles are always preserved.")
                Toggle("Re-compress losslessly (PNG)", isOn: $model.recompress)
            }

            Section("Additional lossless optimization") {
                Toggle("Deep PNG compression", isOn: $model.pngDeepCompression)
                    .help("Tries additional reversible filters and compression strategies. Slower; off by default.")
                Toggle("Maximum PNG compression (Zopfli)", isOn: $model.pngZopfli)
                    .help("Spends extra CPU finding a smaller PNG compression stream. Much slower; off by default.")
                Toggle("Reduce PNG color storage exactly", isOn: $model.pngReduceRepresentation)
                    .help("Uses exact palettes, removes fully opaque alpha, and reduces precision only when every sample is exactly representable. Off by default.")
                Toggle("Optimize PNG chunks and profiles", isOn: $model.pngOptimizeStructure)
                    .help("Combines image chunks and recompresses retained color profiles without changing their contents. Off by default.")
                Toggle("Optimize JPEG Huffman coding", isOn: $model.jpegOptimizeHuffman)
                    .help("Recompresses existing JPEG coefficients without changing image quality. Off by default.")
                Toggle("Try progressive JPEG encoding", isOn: $model.jpegProgressive)
                    .help("Tries progressive scan encoding of the existing coefficients and keeps it only if smaller. Off by default.")
                Toggle("Recompress GIF image data", isOn: $model.gifRecompress)
                    .help("Recompresses frame indices while preserving palettes, frame layout, transparency, timing, and looping. Off by default.")
                Text("All additional methods are off by default. Slower methods can save more on suitable images; only smaller results are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Toggle("Keep originals (back up as .bak)", isOn: $model.keepOriginals)
                Text("On: the original is copied to name.bak.ext and the optimized image keeps its original name. Off: the file is optimized in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Brand.teal500)
                    Text("Slimg preserves image pixels and never produces a larger file. Additional methods change how image data is stored; color profiles are kept unless you explicitly choose to strip them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .tint(Brand.teal500)
        .frame(width: 480, height: 720)
        .padding()
    }
}
