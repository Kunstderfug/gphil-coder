import Foundation

struct FolderSyncSafetySettings: Equatable, Sendable {
    let deleteDestinationItems: Bool
    let autoSyncEnabled: Bool
    let needsAcknowledgement: Bool
}

enum FolderSyncSafetyPolicy {
    static let currentAcknowledgementVersion = 1

    static func resolve(
        persistedDeleteDestinationItems: Bool?,
        persistedAutoSyncEnabled: Bool?,
        hasPersistedPairs: Bool,
        acknowledgedVersion: Int?
    ) -> FolderSyncSafetySettings {
        let deleteDestinationItems =
            persistedDeleteDestinationItems ?? (hasPersistedPairs ? true : false)
        let autoSyncEnabled = persistedAutoSyncEnabled ?? true
        let needsAcknowledgement = hasPersistedPairs
            && deleteDestinationItems
            && autoSyncEnabled
            && (acknowledgedVersion ?? 0) < currentAcknowledgementVersion

        return FolderSyncSafetySettings(
            deleteDestinationItems: deleteDestinationItems,
            autoSyncEnabled: autoSyncEnabled,
            needsAcknowledgement: needsAcknowledgement
        )
    }
}
