import GPhilCoderCore
import SwiftUI

extension FolderSyncHistoryTrigger {
    var title: String {
        switch self {
        case .manual: "Manual Run"
        case .automatic: "Automatic Run"
        case .retry: "Retry Run"
        }
    }

    var symbolName: String {
        switch self {
        case .manual: "hand.tap"
        case .automatic: "bolt"
        case .retry: "arrow.clockwise"
        }
    }
}

extension FolderSyncHistoryRun {
    var pairSummary: String {
        switch pairs.count {
        case 0: "folder sync run"
        case 1: pairs[0].title
        default: "\(pairs[0].title) and \(pairs.count - 1) more pair\(pairs.count == 2 ? "" : "s")"
        }
    }

    var resultTitle: String {
        if isNoChange { return "No Changes" }
        if unresolvedOutcomeCount > 0 { return "Outcome Review Required" }
        if counts.failed > 0 { return "Completed with Failures" }
        if counts.cancelled > 0 { return "Cancelled" }
        if counts.skipped > 0 { return "Completed with Skips" }
        return "Completed"
    }

    var summaryColor: Color {
        if unresolvedOutcomeCount > 0 { return .orange }
        if counts.failed > 0 { return .orange }
        if counts.cancelled > 0 { return .red }
        if isNoChange || counts.skipped > 0 { return .secondary }
        return .green
    }
}

extension FolderSyncHistorySettingsSnapshot {
    var summary: String {
        let fileTypes: String
        if let includedFileExtensions {
            fileTypes = includedFileExtensions.isEmpty
                ? "no file types"
                : includedFileExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
        } else {
            fileTypes = "all file types"
        }
        return [
            "Destination layout: \(destinationLayout.title)",
            "overwrite \(overwriteExisting ? "on" : "off")",
            "deletion \(deleteDestinationItems ? "on" : "off")",
            "automatic sync \(automaticSyncEnabled ? "on" : "off")",
            fileTypes
        ].joined(separator: " • ")
    }
}

extension FolderSyncHistoryItemOutcome {
    var title: String {
        switch self {
        case .successful: "Succeeded"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .successful: "checkmark.circle.fill"
        case .skipped: "forward.end.circle"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .successful: .green
        case .skipped: .secondary
        case .failed: .orange
        case .cancelled: .red
        }
    }
}

extension FolderSyncOperationKind {
    var historyTitle: String {
        switch self {
        case .createDirectory: "Create Folder"
        case .copyNew: "Copy New"
        case .copyUpdated: "Overwrite"
        case .deleteFile: "Delete File"
        case .deleteDirectory: "Delete Folder"
        }
    }
}

extension FolderSyncRetentionMechanism {
    var historyDescription: String {
        switch self {
        case .trash: "Prior item retained in Trash"
        case .sameVolumeQuarantine: "Prior item retained in same-volume quarantine"
        }
    }
}

extension FolderSyncHistoryItem {
    var historyOutcomeTitle: String {
        requiresOutcomeReview ? "Review Required" : outcome.title
    }

    var historyOutcomeSymbolName: String {
        requiresOutcomeReview ? "exclamationmark.triangle.fill" : outcome.symbolName
    }

    var historyOutcomeColor: Color {
        requiresOutcomeReview ? .orange : outcome.color
    }

    var accessibilitySummary: String {
        var parts = [
            "\(kind.historyTitle), \(relativePath)",
            "Outcome: \(historyOutcomeTitle)",
            "Destination: \(destinationPath)"
        ]
        if let outcomeMessage, !outcomeMessage.isEmpty { parts.append(outcomeMessage) }
        if let recovery { parts.append(recovery.mechanism.historyDescription) }
        return parts.joined(separator: ". ")
    }
}

extension FolderSyncRecoveryRecord.Action {
    var title: String {
        switch self {
        case .createdItem: "Created Item"
        case .replacedItem: "Replaced Item"
        case .deletedItem: "Deleted Item"
        }
    }
}

extension FolderSyncRecoveryRecord.State {
    var title: String {
        switch self {
        case .intent: "Intent Recorded"
        case .retained: "Retained"
        case .applied: "Ready"
        case .rollingBack: "Rolling Back"
        case .recoveryFailed: "Needs Attention"
        }
    }

    var symbolName: String {
        switch self {
        case .intent: "clock"
        case .retained, .applied: "archivebox.fill"
        case .rollingBack: "arrow.uturn.backward.circle.fill"
        case .recoveryFailed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .intent: .secondary
        case .retained, .applied: .teal
        case .rollingBack: .indigo
        case .recoveryFailed: .orange
        }
    }
}

extension FolderSyncRollbackOutcome {
    var historySymbolName: String {
        switch self {
        case .restored: "checkmark.circle.fill"
        case .skipped: "forward.end.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var historyColor: Color {
        switch self {
        case .restored: .green
        case .skipped: .secondary
        case .failed: .orange
        }
    }
}

extension FolderSyncRecoveryRecord {
    var accessibilitySummary: String {
        var parts = ["\(action.title), \(state.title)", "Target: \(targetPath)"]
        if let retentionMechanism {
            parts.append(retentionMechanism.historyDescription)
        } else if action == .createdItem {
            parts.append("Rollback removes this run-created item only if it is unchanged")
        }
        if let failureMessage, !failureMessage.isEmpty { parts.append(failureMessage) }
        return parts.joined(separator: ". ")
    }
}
