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
                    Text("Slimg never changes pixels and never produces a larger file. JPEG and HEIC image data is preserved; PNG image data is only re-deflated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .tint(Brand.teal500)
        .frame(width: 420)
        .padding()
    }
}
