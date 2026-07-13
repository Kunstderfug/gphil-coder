import AppKit
import Foundation
import GPhilCoderCore

/// Owns Folder Sync modal UI so planning and view-model coordination remain
/// independent from AppKit. EncoderViewModel exposes these functions as
/// defaulted, replaceable handlers for focused tests.
@MainActor
enum FolderSyncAppKitPromptBoundary {
    static func confirmDeletionEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable destination deletion?"
        alert.informativeText =
            "Files and folders missing from the origin will be included as recoverable deletion operations. Automatic plans containing any deletion always pause in full for manual review."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable Deletion")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmDestructivePlan(_ summary: FolderSyncDestructiveSummary) -> Bool {
        let content = destructivePromptContent(summary)
        let alert = NSAlert()
        alert.messageText = content.message
        alert.informativeText = content.details.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply Reviewed Plan")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func destructivePromptContent(
        _ summary: FolderSyncDestructiveSummary
    ) -> (message: String, details: [String]) {
        let combinedBytes = summary.overwriteBytes + summary.deleteBytes
        var details = [
            "\(summary.operationCount) destructive item\(summary.operationCount == 1 ? "" : "s") across \(summary.affectedPairCount) folder pair\(summary.affectedPairCount == 1 ? "" : "s") (\(combinedBytes.formattedFileSize)).",
            "Affected pairs: \(summary.pairTitles.joined(separator: ", "))"
        ]
        if summary.overwriteCount > 0 {
            details.append(
                "\(summary.overwriteCount) existing item\(summary.overwriteCount == 1 ? "" : "s") will be replaced (\(summary.overwriteBytes.formattedFileSize))."
            )
        }
        if summary.deleteCount > 0 {
            details.append(
                "\(summary.deleteCount) destination item\(summary.deleteCount == 1 ? "" : "s") will be removed (\(summary.deleteBytes.formattedFileSize))."
            )
        }
        details.append("Prior destination content will be retained for Sync recovery.")
        return ("Apply destructive folder sync plan?", details)
    }

    static func confirmPairReplacement(
        currentPairCount: Int,
        newPairCount: Int
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace current sync pairs?"
        alert.informativeText =
            "Loading this file will replace the current \(currentPairCount) sync pair\(currentPairCount == 1 ? "" : "s") with \(newPairCount) pair\(newPairCount == 1 ? "" : "s")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
