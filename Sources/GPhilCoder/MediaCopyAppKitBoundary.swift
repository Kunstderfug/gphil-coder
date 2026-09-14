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
    /// Overridable repair-directory provider so headless tests can drive the
    /// real `repairMediaCopyWorkflow` entry point without a modal open panel.
    /// Production behavior is unchanged: the default is the live panel below.
    /// Overriding tests must restore the default in teardown.
    static var repairDirectoryProvider: (URL) -> URL? = { missingURL in
        MediaCopyAppKitBoundary.chooseRepairDirectory(for: missingURL)
    }

    /// Overridable name prompt so headless tests can drive Save as Workflow
    /// without a modal alert. Production behavior is unchanged: the default
    /// is the live alert below. Overriding tests must restore the default
    /// in teardown.
    static var savedWorkflowNameProvider: () -> String? = {
        MediaCopyAppKitBoundary.promptSavedWorkflowName()
    }

    /// Overridable delete confirmation so headless tests can drive Delete
    /// Workflow without a modal alert. Overriding tests must restore the
    /// default in teardown.
    static var deleteSavedWorkflowConfirmProvider: (String) -> Bool = { name in
        MediaCopyAppKitBoundary.confirmDeleteSavedWorkflow(named: name)
    }

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

    static func promptSavedWorkflowName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save as Workflow"
        alert.informativeText = "Name this file copy queue so you can load it again later."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = ""
        textField.selectText(nil)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }

    static func confirmDeleteSavedWorkflow(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete saved workflow?"
        alert.informativeText = "This will delete \(name) from the saved-workflow library. The current copy queue is unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
