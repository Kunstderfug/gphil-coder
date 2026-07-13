import Foundation
import GPhilCoderCore

enum FolderSyncRetentionMechanism: String, Codable, Equatable, Sendable {
    case trash
    case sameVolumeQuarantine
}

struct FolderSyncMutationResult: Equatable, Sendable {
    let operationResult: FolderSyncOperationResult
    let retentionMechanism: FolderSyncRetentionMechanism?
    let recoveryRecordID: UUID?
}

enum FolderSyncRollbackOutcome: String, Codable, Equatable, Sendable {
    case restored
    case skipped
    case failed
}

struct FolderSyncRollbackItemResult: Equatable, Sendable {
    let recordID: UUID
    let targetPath: String
    let outcome: FolderSyncRollbackOutcome
    let message: String
}

struct FolderSyncRollbackReport: Equatable, Sendable {
    let items: [FolderSyncRollbackItemResult]

    var restored: Int { items.count { $0.outcome == .restored } }
    var skipped: Int { items.count { $0.outcome == .skipped } }
    var failed: Int { items.count { $0.outcome == .failed } }
}

struct FolderSyncRecoveryRecord: Codable, Equatable, Identifiable, Sendable {
    enum Action: String, Codable, Sendable {
        case createdItem
        case replacedItem
        case deletedItem
    }

    enum State: String, Codable, Sendable {
        case intent
        case retained
        case applied
        case rollingBack
        case recoveryFailed
    }

    let id: UUID
    let runID: UUID
    let sequence: Int64
    let operationID: String
    let operationKind: FolderSyncOperationKind
    let action: Action
    let destinationRootPath: String
    let targetPath: String
    let sourcePath: String?
    var retainedPath: String?
    var retentionMechanism: FolderSyncRetentionMechanism?
    var appliedFingerprint: FolderSyncRecoveryFingerprint?
    var state: State
    var failureMessage: String?
}

struct FolderSyncRecoveryFingerprint: Codable, Equatable, Sendable {
    let isDirectory: Bool
    let fileSizeBytes: Int64
    let modificationDate: Date?
    let contentSignature: UInt64?
}

protocol FolderSyncRecoveryJournalStore: AnyObject {
    func load() throws -> [FolderSyncRecoveryRecord]
    func save(_ records: [FolderSyncRecoveryRecord]) throws
}

final class FolderSyncVersionedJSONRecoveryStore: FolderSyncRecoveryJournalStore {
    static let currentVersion = 1

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [FolderSyncRecoveryRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try VersionedBlob.decodeEnvelope(
            from: data,
            currentVersion: Self.currentVersion,
            allowLegacyBareArray: false
        ).get()
    }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try VersionedBlob.encode(records, currentVersion: Self.currentVersion)
        try data.write(to: fileURL, options: [.atomic])
    }
}

protocol FolderSyncTrashBoundary {
    func moveToTrash(_ url: URL) throws -> URL
}

struct FileManagerFolderSyncTrashBoundary: FolderSyncTrashBoundary {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL = resultingURL as URL? else {
            throw CocoaError(.fileNoSuchFile)
        }
        return resultingURL
    }
}
