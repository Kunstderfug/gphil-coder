import AppKit
import SwiftUI

private enum MainWindowConfiguration {
    static let contentSafeWidth: CGFloat = 1320
    static let contentSafeHeight: CGFloat = 940
    static let frameAutosaveName = "GPhilCoderMainWindow"

    static var contentSafeSize: NSSize {
        NSSize(width: contentSafeWidth, height: contentSafeHeight)
    }
}

enum AppWindowID {
    static let renameSettings = "rename-settings"
}

@main
struct GPhilCoderApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var encoder = EncoderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(encoder)
                .frame(
                    minWidth: MainWindowConfiguration.contentSafeWidth,
                    minHeight: MainWindowConfiguration.contentSafeHeight
                )
                .background(WindowLifecycleBridge(encoder: encoder, appDelegate: appDelegate))
                .onAppear {
                    appDelegate.encoder = encoder
                    AppNotifier.configure()
                    encoder.refreshNotificationPermission()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: MainWindowConfiguration.contentSafeWidth,
            height: MainWindowConfiguration.contentSafeHeight
        )
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

            CommandMenu("Workflow") {
                Button("Start Encoding") {
                    encoder.startEncoding()
                }
                .keyboardShortcut("e")
                .disabled(!encoder.canEncode)

                Button("Cancel Active Operation") {
                    if encoder.isEncoding {
                        encoder.cancelEncoding()
                    } else {
                        encoder.cancelMediaCopy()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!encoder.isEncoding && !encoder.isMediaCopyBusy)

                Divider()

                Button("Refresh File Management Preview") {
                    encoder.refreshCurrentFileManagementPreview()
                }
                .keyboardShortcut("r")
                .disabled(encoder.isEncoding || encoder.isMediaCopyBusy)

                Divider()

                Button("Save Encoding Queue...") {
                    encoder.saveQueue()
                }
                .disabled(!encoder.canSaveQueue)

                Button("Load Encoding Queue...") {
                    encoder.loadQueue()
                }
                .disabled(encoder.isEncoding)
            }
        }

        Window("Rename Settings", id: AppWindowID.renameSettings) {
            MediaRenameSettingsWindow()
                .environmentObject(encoder)
        }
        .defaultSize(width: 430, height: 420)
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var encoder: EncoderViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard canCloseOrTerminate() else {
            return .terminateCancel
        }

        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canCloseOrTerminate()
    }

    private func canCloseOrTerminate() -> Bool {
        guard let encoder, encoder.isQuitBlockedByActiveProcess else {
            return true
        }

        encoder.reportQuitBlockedByActiveProcess()
        showQuitBlockedAlert(message: encoder.activeProcessQuitBlockedMessage)
        return false
    }

    private func showQuitBlockedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "GPhil Coder is busy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct WindowLifecycleBridge: NSViewRepresentable {
    @ObservedObject var encoder: EncoderViewModel
    let appDelegate: AppLifecycleDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attachDelegate(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        appDelegate.encoder = encoder
        attachDelegate(to: view)
    }

    private func attachDelegate(to view: NSView) {
        DispatchQueue.main.async {
            appDelegate.encoder = encoder
            if let window = view.window {
                window.minSize = MainWindowConfiguration.contentSafeSize
                _ = window.setFrameAutosaveName(MainWindowConfiguration.frameAutosaveName)
                if window.delegate !== appDelegate {
                    window.delegate = appDelegate
                }
            }
        }
    }
}
