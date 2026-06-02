import SwiftUI

@main
struct SlimgApp: App {
    @StateObject private var model = OptimizerModel()

    var body: some Scene {
        WindowGroup("Slimg") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
