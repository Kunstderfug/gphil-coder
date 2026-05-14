import SwiftUI

@main
struct GPhilCoderApp: App {
    @StateObject private var encoder = EncoderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(encoder)
                .frame(minWidth: 1120, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    encoder.addFiles()
                }
                .keyboardShortcut("o")

                Button("Add Folder...") {
                    encoder.addFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
