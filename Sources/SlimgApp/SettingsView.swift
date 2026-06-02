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
                .help("Removing color profiles can shift how colors appear. Off by default to stay visually lossless.")
                Toggle("Re-compress losslessly (PNG)", isOn: $model.recompress)
            }

            Section("Output") {
                Toggle("Keep originals (write .min copies)", isOn: $model.saveCopies)
            }

            Section {
                Text("Slimg never changes pixels and never produces a larger file. JPEG scan data is preserved exactly; PNG image data is only re-deflated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
