import Foundation

final class FolderSyncServices {
    let historyStore: FolderSyncHistoryStore
    let mutationService: RecoverableFolderSyncMutationService

    init(
        storageRoot: URL,
        trashBoundary: FolderSyncTrashBoundary? = nil,
        fileManager: FileManager = .default
    ) throws {
        historyStore = FolderSyncHistoryStore(
            fileURL: storageRoot.appendingPathComponent("history.json", isDirectory: false)
        )
        let recoveryStore = FolderSyncVersionedJSONRecoveryStore(
            fileURL: storageRoot.appendingPathComponent("recovery.json", isDirectory: false),
            fileManager: fileManager
        )
        if let trashBoundary {
            mutationService = try RecoverableFolderSyncMutationService(
                store: recoveryStore,
                trash: trashBoundary,
                fileManager: fileManager
            )
        } else {
            mutationService = try RecoverableFolderSyncMutationService(
                store: recoveryStore,
                fileManager: fileManager
            )
        }
    }

    static func liveStorageRoot(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("GPhilCoder", isDirectory: true)
            .appendingPathComponent("FolderSync", isDirectory: true)
    }
}
