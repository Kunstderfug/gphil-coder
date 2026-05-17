import AppKit
import Foundation
@preconcurrency import UserNotifications

@MainActor
enum AppNotifier {
    private static let notificationDelegate = ForegroundNotificationDelegate()

    static func configure() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    static func refreshAuthorization(
        completion: @escaping @MainActor (NotificationPermissionState) -> Void
    ) {
        configure()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state = NotificationPermissionState(settings.authorizationStatus)
            Task { @MainActor in
                completion(state)
            }
        }
    }

    static func requestAuthorization(
        completion: @escaping @MainActor (NotificationPermissionState, String?) -> Void
    ) {
        configure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, error in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let state = NotificationPermissionState(settings.authorizationStatus)
                Task { @MainActor in
                    completion(state, error?.localizedDescription)
                }
            }
        }
    }

    static func notifyIfAppInactive(title: String, body: String) {
        guard !NSApplication.shared.isActive else { return }
        configure()

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "gphilcoder-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    static func sendTestNotification(completion: @escaping @MainActor (String?) -> Void) {
        configure()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else {
                Task { @MainActor in
                    completion("Notifications are not enabled for GPhilCoder.")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "GPhilCoder notifications are working"
            content.body = "Completion alerts will appear when the app is in the background."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "gphilcoder-test-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                Task { @MainActor in
                    completion(error?.localizedDescription)
                }
            }
        }
    }

    static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.gphil.coder"
        let urlStrings = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]

        var openedSettingsURL = false
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                openedSettingsURL = true
            }
        }

        guard !openedSettingsURL,
            let settingsAppURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.systempreferences"
            )
        else {
            return
        }

        NSWorkspace.shared.openApplication(
            at: settingsAppURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

enum NotificationPermissionState: Equatable {
    case unknown
    case notDetermined
    case enabled
    case denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorized, .provisional, .ephemeral:
            self = .enabled
        case .denied:
            self = .denied
        @unknown default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .unknown:
            "Notifications unknown"
        case .notDetermined:
            "Notifications off"
        case .enabled:
            "Notifications on"
        case .denied:
            "Notifications denied"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            "Notification permission has not been checked yet."
        case .notDetermined:
            "Enable notifications to get completion alerts when GPhilCoder is in the background."
        case .enabled:
            "Completion alerts will appear when GPhilCoder is in the background."
        case .denied:
            "Enable notifications for GPhilCoder in macOS System Settings."
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            "bell"
        case .notDetermined:
            "bell.badge"
        case .enabled:
            "bell.fill"
        case .denied:
            "bell.slash.fill"
        }
    }

    var canRequestFromApp: Bool {
        self == .notDetermined || self == .unknown
    }
}
