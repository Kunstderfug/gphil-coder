import AppKit
import Foundation
import GPhilCoderCore
import UniformTypeIdentifiers

enum MediaCopyJobFile {
    static let fileExtension = "job"

    static var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .json
    }
}

/// Owns Copy-specific macOS dialogs so workflow state and persistence remain
/// independent from AppKit and can be exercised in focused tests.
@MainActor
enum MediaCopyAppKitBoundary {
    static func chooseSaveJobURL(initialDirectory: URL?, defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save File Copy Job"
        panel.prompt = "Save Job"
        panel.allowedContentTypes = [MediaCopyJobFile.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = initialDirectory
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseLoadJobURL(initialDirectory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Load File Copy Job"
        panel.prompt = "Load Job"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [MediaCopyJobFile.contentType, .json]
        panel.directoryURL = initialDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseRepairDirectory(for missingURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Relink \(missingURL.lastPathComponent)"
        panel.prompt = "Use Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = missingURL.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func resolveConflicts(in plans: [MediaCopyBatchPlan]) -> MediaCopyConflictResolution? {
        let conflictCount = plans.reduce(0) { $0 + $1.conflictCount }
        guard conflictCount > 0 else { return .skipExisting }

        let plannedItemCount = plans.reduce(0) { $0 + $1.candidateCount + $1.directoryCount }
        let destinationDescription =
            plans.count == 1
            ? plans[0].destinationRoot.path(percentEncoded: false)
            : "\(plans.count) queued destinations"

        let alert = NSAlert()
        alert.messageText = "Destination conflicts found"
        alert.informativeText =
            "\(conflictCount) of \(plannedItemCount) planned items conflict under \(destinationDescription). A conflict means an item already exists or selected sources target the same final path. Skip keeps an existing item or the first selected source for a shared path; Replace lets later planned items replace it. Cancel leaves the destination unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Skip Conflicts")
        alert.addButton(withTitle: "Replace Conflicts")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .skipExisting
        case .alertSecondButtonReturn:
            return .replaceExisting
        default:
            return nil
        }
    }
}
