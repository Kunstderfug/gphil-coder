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
    static let encodingPresets = "encoding-presets"
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
                    } else if encoder.isFolderSyncBusy {
                        encoder.cancelFolderSync()
                    } else {
                        encoder.cancelMediaCopy()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(
                    !encoder.isEncoding
                        && !encoder.canCancelMediaCopy
                        && !encoder.isFolderSyncBusy
                )

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

        Window("Encoding Presets", id: AppWindowID.encodingPresets) {
            EncodingPresetManagerWindow()
                .environmentObject(encoder)
        }
        .defaultSize(width: 620, height: 520)
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var encoder: EncoderViewModel? {
        didSet {
            refreshActivityStatusItem()
        }
    }

    private weak var mainWindow: NSWindow?
    private var activityStatusItem: NSStatusItem?
    private var activityStatusSummaryItem: NSMenuItem?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        showMainWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshActivityStatusItem()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard canCloseOrTerminate() else {
            return .terminateCancel
        }

        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else {
            return true
        }

        guard canCloseOrTerminate() else {
            return false
        }

        if encoder?.isMenuBarActivityActive == true {
            hideMainWindowToStatusItem()
            return false
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window === mainWindow
        else {
            return
        }

        if encoder?.isMenuBarActivityActive == true {
            hideMainWindowToStatusItem()
        } else {
            refreshActivityStatusItem()
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        refreshStatusItemIfMainWindow(notification.object)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        refreshStatusItemIfMainWindow(notification.object)
    }

    func windowDidResignMain(_ notification: Notification) {
        refreshStatusItemIfMainWindow(notification.object)
    }

    func configureMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.minSize = MainWindowConfiguration.contentSafeSize
        _ = window.setFrameAutosaveName(MainWindowConfiguration.frameAutosaveName)
        if window.delegate !== self {
            window.delegate = self
        }
        if let miniaturizeButton = window.standardWindowButton(.miniaturizeButton) {
            miniaturizeButton.target = self
            miniaturizeButton.action = #selector(handleMiniaturizeButton(_:))
        }
    }

    func refreshActivityStatusItem() {
        guard let encoder,
            encoder.isMenuBarActivityActive,
            shouldShowActivityStatusItem
        else {
            removeActivityStatusItem()
            return
        }

        let statusItem = activityStatusItem ?? makeActivityStatusItem()
        activityStatusItem = statusItem
        statusItem.button?.toolTip = "GPhil Coder: \(encoder.menuBarActivityTitle)."
        activityStatusSummaryItem?.title = encoder.menuBarActivityTitle
    }

    private var shouldShowActivityStatusItem: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isMiniaturized || !mainWindow.isVisible
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

    private func makeActivityStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = Self.loadStatusItemAppIcon()
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        }

        let menu = NSMenu()
        let summaryItem = NSMenuItem(title: "GPhil Coder active", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        activityStatusSummaryItem = summaryItem
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let showItem = NSMenuItem(
            title: "Show GPhil Coder",
            action: #selector(showGPhilCoderFromStatusItem(_:)),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        let quitItem = NSMenuItem(
            title: "Quit GPhil Coder",
            action: #selector(quitGPhilCoderFromStatusItem(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        return statusItem
    }

    private static func loadStatusItemAppIcon() -> NSImage? {
        let image =
            bundledAppIcon()
            ?? sourceAppIcon()
            ?? NSApp.applicationIconImage
        image?.accessibilityDescription = "GPhil Coder activity"
        image?.isTemplate = false
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func bundledAppIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private static func sourceAppIcon() -> NSImage? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/appicon.png")
        return NSImage(contentsOf: url)
    }

    private func removeActivityStatusItem() {
        if let activityStatusItem {
            NSStatusBar.system.removeStatusItem(activityStatusItem)
        }
        activityStatusItem = nil
        activityStatusSummaryItem = nil
    }

    @objc private func handleMiniaturizeButton(_ sender: Any?) {
        guard encoder?.isMenuBarActivityActive == true else {
            mainWindow?.miniaturize(sender)
            return
        }

        hideMainWindowToStatusItem()
    }

    @objc private func showGPhilCoderFromStatusItem(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func quitGPhilCoderFromStatusItem(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func hideMainWindowToStatusItem() {
        guard let mainWindow else { return }

        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.orderOut(nil)
        refreshActivityStatusItem()
    }

    private func showMainWindow() {
        guard let mainWindow else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshActivityStatusItem()
    }

    private func refreshStatusItemIfMainWindow(_ object: Any?) {
        guard let window = object as? NSWindow,
            window === mainWindow
        else {
            return
        }

        refreshActivityStatusItem()
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
                appDelegate.configureMainWindow(window)
            }
            appDelegate.refreshActivityStatusItem()
        }
    }
}
