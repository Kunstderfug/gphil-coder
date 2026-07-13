import Foundation

func clearViewModelDefaultsForTests() {
    let keys = [
        "syncFolderPairs",
        "syncAutoSyncEnabled",
        "syncDestinationLayout",
        "syncFileFilter",
        "syncCustomFileExtensions",
        "syncOverwriteExisting",
        "syncDeleteDestinationItems",
        "syncSafetyAcknowledgementVersion",
        "completionNotificationsEnabled"
    ]
    for key in keys {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
