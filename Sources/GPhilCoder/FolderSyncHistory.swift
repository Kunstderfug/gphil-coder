import Foundation
import GPhilCoderCore

enum FolderSyncHistoryTrigger: String, Codable, Sendable {
    case manual
    case automatic
    case retry
}

struct FolderSyncHistoryPairSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let originPath: String
    let destinationPath: String
}

struct FolderSyncHistorySettingsSnapshot: Codable, Equatable, Sendable {
    let destinationLayout: SyncDestinationLayout
    let deleteDestinationItems: Bool
    let overwriteExisting: Bool
    let includedFileExtensions: [String]?
    let automaticSyncEnabled: Bool
}

enum FolderSyncHistoryItemOutcome: String, Codable, Sendable {
    case successful
    case skipped
    case failed
    case cancelled
}

enum FolderSyncHistoryOutcomeRecordingState: String, Codable, Sendable {
    case finalized
    case requiresReview
}

struct FolderSyncHistoryRecoveryReference: Codable, Equatable, Sendable {
    let recordID: UUID
    let mechanism: FolderSyncRetentionMechanism
}

struct FolderSyncHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let pairID: UUID
    let operationID: String
    let kind: FolderSyncOperationKind
    let sourcePath: String?
    let destinationPath: String
    let relativePath: String
    let fileSizeBytes: Int64
    let outcome: FolderSyncHistoryItemOutcome
    let outcomeMessage: String?
    let retryEligible: Bool
    let recovery: FolderSyncHistoryRecoveryReference?
    /// Missing values are legacy finalized records. `requiresReview` is
    /// persisted before mutation so a later write failure cannot disguise a
    /// changed item as merely cancelled.
    let outcomeRecordingState: FolderSyncHistoryOutcomeRecordingState?

    init(
        id: UUID,
        pairID: UUID,
        operationID: String,
        kind: FolderSyncOperationKind,
        sourcePath: String?,
        destinationPath: String,
        relativePath: String,
        fileSizeBytes: Int64,
        outcome: FolderSyncHistoryItemOutcome,
        outcomeMessage: String?,
        retryEligible: Bool,
        recovery: FolderSyncHistoryRecoveryReference?,
        outcomeRecordingState: FolderSyncHistoryOutcomeRecordingState? = .finalized
    ) {
        self.id = id
        self.pairID = pairID
        self.operationID = operationID
        self.kind = kind
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.outcome = outcome
        self.outcomeMessage = outcomeMessage
        self.retryEligible = retryEligible
        self.recovery = recovery
        self.outcomeRecordingState = outcomeRecordingState
    }

    var requiresOutcomeReview: Bool {
        outcomeRecordingState == .requiresReview
    }
}

struct FolderSyncHistoryCounts: Equatable, Sendable {
    let planned: Int
    let successful: Int
    let skipped: Int
    let failed: Int
    let cancelled: Int
}

struct FolderSyncHistoryRetryCandidate: Identifiable, Equatable, Sendable {
    let runID: UUID
    let historyItemID: UUID
    let pairID: UUID
    let operationID: String
    let kind: FolderSyncOperationKind
    let sourcePath: String?
    let destinationPath: String
    let relativePath: String
    let fileSizeBytes: Int64

    var id: UUID { historyItemID }
}

struct FolderSyncHistoryRollbackItem: Codable, Equatable, Sendable {
    let recordID: UUID
    let targetPath: String
    let outcome: FolderSyncRollbackOutcome
    let message: String
}

struct FolderSyncHistoryRollback: Codable, Equatable, Sendable {
    let completedAt: Date
    let items: [FolderSyncHistoryRollbackItem]

    var restored: Int { items.count { $0.outcome == .restored } }
    var skipped: Int { items.count { $0.outcome == .skipped } }
    var failed: Int { items.count { $0.outcome == .failed } }
}

struct FolderSyncHistoryRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let trigger: FolderSyncHistoryTrigger
    let startedAt: Date
    let completedAt: Date
    let pairs: [FolderSyncHistoryPairSnapshot]
    let settings: FolderSyncHistorySettingsSnapshot
    let items: [FolderSyncHistoryItem]
    let rollback: FolderSyncHistoryRollback?

    init(
        id: UUID,
        trigger: FolderSyncHistoryTrigger,
        startedAt: Date,
        completedAt: Date,
        pairs: [FolderSyncHistoryPairSnapshot],
        settings: FolderSyncHistorySettingsSnapshot,
        items: [FolderSyncHistoryItem],
        rollback: FolderSyncHistoryRollback? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.pairs = pairs
        self.settings = settings
        self.items = items
        self.rollback = rollback
    }

    var counts: FolderSyncHistoryCounts {
        let finalizedItems = items.filter { !$0.requiresOutcomeReview }
        return FolderSyncHistoryCounts(
            planned: items.count,
            successful: finalizedItems.count(where: { $0.outcome == .successful }),
            skipped: finalizedItems.count(where: { $0.outcome == .skipped }),
            failed: finalizedItems.count(where: { $0.outcome == .failed }),
            cancelled: finalizedItems.count(where: { $0.outcome == .cancelled })
        )
    }

    var isNoChange: Bool {
        items.isEmpty
    }

    var retryCandidates: [FolderSyncHistoryRetryCandidate] {
        items.compactMap { item in
            guard !item.requiresOutcomeReview,
                item.retryEligible,
                item.outcome == .failed || item.outcome == .cancelled
            else { return nil }
            return FolderSyncHistoryRetryCandidate(
                runID: id,
                historyItemID: item.id,
                pairID: item.pairID,
                operationID: item.operationID,
                kind: item.kind,
                sourcePath: item.sourcePath,
                destinationPath: item.destinationPath,
                relativePath: item.relativePath,
                fileSizeBytes: item.fileSizeBytes
            )
        }
    }

    var unresolvedOutcomeCount: Int {
        items.count(where: \.requiresOutcomeReview)
    }
}

struct FolderSyncHistoryLoadFailure: Equatable, Sendable {
    let problem: DecodeProblem
    let sourceData: Data?
}

enum FolderSyncHistoryStoreError: Error, Equatable, Sendable {
    case unresolvedLoadFailure(DecodeProblem)
}

final class FolderSyncHistoryStore {
    static let currentVersion = 1

    let fileURL: URL
    let retentionLimit: Int
    private let dataWriter: (Data, URL) throws -> Void
    /// Newest-first runs that have successfully loaded or persisted.
    private(set) var runs: [FolderSyncHistoryRun] = []
    /// Preserves an unreadable document and prevents an accidental overwrite.
    private(set) var lastLoadFailure: FolderSyncHistoryLoadFailure?

    init(
        fileURL: URL,
        retentionLimit: Int = 100,
        dataWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.retentionLimit = max(1, retentionLimit)
        self.dataWriter = dataWriter
        _ = reload()
    }

    @discardableResult
    func reload() -> Result<[FolderSyncHistoryRun], DecodeProblem> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            runs = []
            lastLoadFailure = nil
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let problem = DecodeProblem.corrupt(underlying: String(describing: error))
            lastLoadFailure = FolderSyncHistoryLoadFailure(problem: problem, sourceData: nil)
            return .failure(problem)
        }

        let result: Result<[FolderSyncHistoryRun], DecodeProblem> = VersionedBlob.decodeEnvelope(
            from: data,
            currentVersion: Self.currentVersion,
            allowLegacyBareArray: false
        )
        switch result {
        case .success(let decodedRuns):
            runs = Array(decodedRuns.prefix(retentionLimit))
            lastLoadFailure = nil
            return .success(runs)
        case .failure(let problem):
            lastLoadFailure = FolderSyncHistoryLoadFailure(problem: problem, sourceData: data)
            return .failure(problem)
        }
    }

    func record(_ run: FolderSyncHistoryRun) throws {
        if let lastLoadFailure {
            throw FolderSyncHistoryStoreError.unresolvedLoadFailure(lastLoadFailure.problem)
        }
        let retainedRuns = Array(
            ([run] + runs.filter { $0.id != run.id }).prefix(retentionLimit)
        )
        let data = try VersionedBlob.encode(
            retainedRuns,
            currentVersion: Self.currentVersion
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try dataWriter(data, fileURL)
        runs = retainedRuns
        lastLoadFailure = nil
    }

    /// Clears only the history document. Recovery journals and payloads are
    /// intentionally outside this store's interface.
    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        runs = []
        lastLoadFailure = nil
    }
}
