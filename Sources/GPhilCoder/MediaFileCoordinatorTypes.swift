import Foundation
import GPhilCoderCore

struct MediaCopyResult: Sendable {
    var total: Int
    var copied = 0
    var skippedExisting = 0
    var failed = 0
    var failedNames: [String] = []
    var createdDirectories = 0
    var failedDirectories = 0
    var failedDirectoryNames: [String] = []
    var cancelled = false

    init(total: Int = 0, cancelled: Bool = false) {
        self.total = total
        self.cancelled = cancelled
    }
}

struct TrashableFileItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let sourceRoot: URL?
    let relativeDirectory: String?
    let fileSizeBytes: Int64

    init(
        id: UUID = UUID(),
        url: URL,
        sourceRoot: URL?,
        relativeDirectory: String?,
        fileSizeBytes: Int64
    ) {
        self.id = id
        self.url = url
        self.sourceRoot = sourceRoot
        self.relativeDirectory = relativeDirectory
        self.fileSizeBytes = fileSizeBytes
    }

    init(audioInput item: AudioInputItem) {
        self.init(
            id: item.id,
            url: item.url,
            sourceRoot: item.sourceRoot,
            relativeDirectory: item.relativeDirectory,
            fileSizeBytes: item.fileSizeBytes
        )
    }

    init(deleteCandidate candidate: MediaDeleteCandidate) {
        self.init(
            url: candidate.sourceURL,
            sourceRoot: candidate.sourceRoot,
            relativeDirectory: candidate.relativeDirectory,
            fileSizeBytes: candidate.fileSizeBytes
        )
    }

    var name: String {
        url.lastPathComponent
    }
}

enum TrashMoveRecordResult {
    case restoreLedgerRecorded
    case emergencyJournalOnly
}

struct MediaTrashResult: Sendable {
    var total: Int
    var moved = 0
    var failed = 0
    var emergencyOnly = 0
    var failedNames: [String] = []
    var cancelled = false

    init(total: Int = 0) {
        self.total = total
    }
}

struct MediaRenameHistoryItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let originalPath: String
    let renamedPath: String
    let originalName: String
    let renamedName: String
    let fileSizeBytes: Int64

    init(
        id: UUID = UUID(),
        originalPath: String,
        renamedPath: String,
        originalName: String,
        renamedName: String,
        fileSizeBytes: Int64
    ) {
        self.id = id
        self.originalPath = originalPath
        self.renamedPath = renamedPath
        self.originalName = originalName
        self.renamedName = renamedName
        self.fileSizeBytes = fileSizeBytes
    }
}

struct MediaRenameHistoryTransaction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let actionTitle: String
    let createdAt: Date
    let items: [MediaRenameHistoryItem]

    init(
        id: UUID = UUID(),
        actionTitle: String,
        createdAt: Date = Date(),
        items: [MediaRenameHistoryItem]
    ) {
        self.id = id
        self.actionTitle = actionTitle
        self.createdAt = createdAt
        self.items = items
    }

    func replacingItems(_ nextItems: [MediaRenameHistoryItem]) -> MediaRenameHistoryTransaction {
        MediaRenameHistoryTransaction(
            id: UUID(),
            actionTitle: actionTitle,
            createdAt: createdAt,
            items: nextItems
        )
    }
}

struct MediaRenameResult: Sendable {
    var total: Int
    var renamed = 0
    var failed = 0
    var failedNames: [String] = []
    var historyItems: [MediaRenameHistoryItem] = []
    var cancelled = false

    init(total: Int = 0) {
        self.total = total
    }
}

struct MediaRenameHistoryResult: Sendable {
    var total: Int
    var moved = 0
    var failed = 0
    var failedNames: [String] = []
    var movedItems: [MediaRenameHistoryItem] = []
    var cancelled = false

    init(total: Int = 0) {
        self.total = total
    }
}

enum MediaRenameHistoryDirection: Equatable, Sendable {
    case undo
    case redo

    var title: String {
        switch self {
        case .undo:
            "Undo rename"
        case .redo:
            "Redo rename"
        }
    }

    var progressTitle: String {
        switch self {
        case .undo:
            "Undoing rename"
        case .redo:
            "Redoing rename"
        }
    }

    var progressVerb: String {
        switch self {
        case .undo:
            "reverted"
        case .redo:
            "redone"
        }
    }

    var notificationTitle: String {
        switch self {
        case .undo:
            "Rename undo finished"
        case .redo:
            "Rename redo finished"
        }
    }
}
