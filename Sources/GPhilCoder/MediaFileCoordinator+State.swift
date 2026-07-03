import Foundation
import GPhilCoderCore

@MainActor
extension MediaFileCoordinator {
    var isBusy: Bool {
        isMediaCopyScanning || isMediaCopying || isMediaDeleting || isMediaRenaming
    }

    var currentMediaCopySelectedExtensions: Set<String> {
        selectedExtensions(for: mediaCopyFilter) ?? []
    }

    var currentMediaFileNameFilter: MediaFileNameFilter {
        MediaFileNameFilter(query: mediaFileNameFilterQuery)
    }

    var primaryMediaCopySourceRoot: URL? {
        mediaCopySourceRoots.first
    }

    var mediaCopyRunConfiguration: MediaCopyRunConfiguration {
        MediaCopyRunConfiguration(
            sourceRoot: primaryMediaCopySourceRoot,
            destinationRoot: mediaCopyDestinationRoot,
            filter: mediaCopyFilter,
            selectedExtensions: selectedExtensions(for: mediaCopyFilter),
            fileNameFilter: currentMediaFileNameFilter,
            previewLimit: 300
        )
    }

    var mediaPreviewConfiguration: MediaPreviewConfiguration {
        MediaPreviewConfiguration(
            sourceRoots: mediaCopySourceRoots,
            filter: mediaCopyFilter,
            selectedExtensions: selectedExtensions(for: mediaCopyFilter),
            fileNameFilter: currentMediaFileNameFilter,
            renameSettings: currentMediaRenameSettings(),
            previewLimit: 300
        )
    }

    var mediaFileInventoryMatchesCurrentSources: Bool {
        !mediaCopySourceRoots.isEmpty
            && mediaFileInventorySourceRootPaths == currentMediaCopySourceRootPaths
    }

    var currentMediaCopySourceRootPaths: [String] {
        mediaCopySourceRoots.map { $0.standardizedFileURL.path }
    }

    var mediaCopyHasSelectedExtensionsForCurrentFilter: Bool {
        !mediaCopyFilter.supportsExtensionSelection || !currentMediaCopySelectedExtensions.isEmpty
    }

    func selectedExtensions(for filter: MediaFileFilter) -> Set<String>? {
        switch filter {
        case .all:
            return nil
        case .audio:
            return mediaCopyAudioExtensions
        case .video:
            return mediaCopyVideoExtensions
        }
    }

    func currentMediaRenameSettings() -> MediaRenameSettings {
        MediaRenameSettings(
            operation: mediaRenameOperation,
            pattern: mediaRenamePattern,
            findText: mediaRenameFindText,
            replacementText: mediaRenameReplacementText,
            isCaseSensitive: mediaRenameIsCaseSensitive,
            addedText: mediaRenameAddedText,
            textPlacement: mediaRenameTextPlacement,
            caseStyle: mediaRenameCaseStyle,
            sort: mediaRenameSort,
            startIndex: mediaRenameStartIndex,
            indexStep: mediaRenameIndexStep,
            indexPadding: mediaRenameIndexPadding
        )
    }

    func clearInventory() {
        mediaFileInventory = []
        mediaFileInventorySourceRootPaths = []
    }

    func setProgress(_ progress: MediaCopyProgress?) {
        mediaCopyProgress = progress
    }

    func setInventory(_ inventory: [MediaFileInventoryRecord], _ sourceRootPaths: [String]) {
        mediaFileInventory = inventory
        mediaFileInventorySourceRootPaths = sourceRootPaths
    }

    func pushMediaRenameUndoTransaction(_ transaction: MediaRenameHistoryTransaction) {
        guard !transaction.items.isEmpty else { return }
        mediaRenameUndoStack.append(transaction)
        if mediaRenameUndoStack.count > 20 {
            mediaRenameUndoStack.removeFirst(mediaRenameUndoStack.count - 20)
        }
    }

    func pushMediaRenameRedoTransaction(_ transaction: MediaRenameHistoryTransaction) {
        guard !transaction.items.isEmpty else { return }
        mediaRenameRedoStack.append(transaction)
        if mediaRenameRedoStack.count > 20 {
            mediaRenameRedoStack.removeFirst(mediaRenameRedoStack.count - 20)
        }
    }

    func completeRenameHistoryAction(
        _ transaction: MediaRenameHistoryTransaction,
        _ direction: MediaRenameHistoryDirection,
        _ result: MediaRenameHistoryResult
    ) {
        let movedIDs = Set(result.movedItems.map(\.id))
        let remainingItems = transaction.items.filter { !movedIDs.contains($0.id) }

        switch direction {
        case .undo:
            removeMediaRenameTransaction(transaction, fromUndoStack: true)
            if !remainingItems.isEmpty {
                pushMediaRenameUndoTransaction(transaction.replacingItems(remainingItems))
            }
            if !result.movedItems.isEmpty {
                pushMediaRenameRedoTransaction(transaction.replacingItems(result.movedItems))
            }
        case .redo:
            removeMediaRenameTransaction(transaction, fromUndoStack: false)
            if !remainingItems.isEmpty {
                pushMediaRenameRedoTransaction(transaction.replacingItems(remainingItems))
            }
            if !result.movedItems.isEmpty {
                pushMediaRenameUndoTransaction(transaction.replacingItems(result.movedItems))
            }
        }
    }

    private func removeMediaRenameTransaction(
        _ transaction: MediaRenameHistoryTransaction,
        fromUndoStack: Bool
    ) {
        if fromUndoStack {
            if mediaRenameUndoStack.last?.id == transaction.id {
                mediaRenameUndoStack.removeLast()
            } else {
                mediaRenameUndoStack.removeAll { $0.id == transaction.id }
            }
        } else if mediaRenameRedoStack.last?.id == transaction.id {
            mediaRenameRedoStack.removeLast()
        } else {
            mediaRenameRedoStack.removeAll { $0.id == transaction.id }
        }
    }
}
