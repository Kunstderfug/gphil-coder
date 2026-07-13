import AppKit
import Foundation
import GPhilCoderCore
import UniformTypeIdentifiers

@MainActor
extension EncoderViewModel {
    func chooseSyncOriginRoot() {
        guard !isFolderSyncBusy else { return }
        if let url = chooseDirectory(
            title: "Choose Sync Origin Folder",
            prompt: "Use Origin",
            initialURL: syncDraftOriginRoot ?? lastInputDirectoryURL()
        ) {
            syncDraftOriginRoot = url
            rememberInputDirectory(url)
            statusMessage = "Sync origin set to \(url.path(percentEncoded: false))."
        }
    }

    func chooseSyncDestinationRoot() {
        guard !isFolderSyncBusy else { return }
        if let url = chooseDirectory(
            title: "Choose Sync Destination Folder",
            prompt: "Use Destination",
            initialURL: syncDraftDestinationRoot ?? syncDraftOriginRoot ?? lastInputDirectoryURL()
        ) {
            syncDraftDestinationRoot = url
            statusMessage = "Sync destination set to \(url.path(percentEncoded: false))."
        }
    }

    func addSyncFolderPair() {
        guard let originRoot = syncDraftOriginRoot,
            let destinationRoot = syncDraftDestinationRoot
        else {
            statusMessage = "Choose origin and destination folders before adding a sync pair."
            return
        }

        let originPath = originRoot.standardizedFileURL.path(percentEncoded: false)
        let destinationPath = destinationRoot.standardizedFileURL.path(percentEncoded: false)
        let candidatePair = SyncFolderPair(
            originPath: originPath,
            destinationPath: destinationPath,
            state: syncAutoSyncEnabled ? .watching : .idle,
            originBookmarkData: bookmarks.bookmarkData(for: originRoot),
            destinationBookmarkData: bookmarks.bookmarkData(for: destinationRoot)
        )

        if let editingSyncPairID {
            guard let index = syncFolderPairs.firstIndex(where: { $0.id == editingSyncPairID }) else {
                cancelEditingSyncFolderPair()
                statusMessage = "The sync pair being edited no longer exists."
                return
            }
            if syncFolderPairs.contains(where: {
                $0.id != editingSyncPairID && $0.originPath == originPath && $0.destinationPath == destinationPath
            }) {
                statusMessage = "That sync pair is already in the list."
                return
            }

            var editedPair = syncFolderPairs[index]
            editedPair.originPath = originPath
            editedPair.destinationPath = destinationPath
            editedPair.state = editedPair.isEnabled
                ? (syncAutoSyncEnabled ? .watching : .idle)
                : .disabled
            editedPair.lastMessage = "Ready to sync."
            editedPair.originBookmarkData = bookmarks.bookmarkData(for: originRoot)
            editedPair.destinationBookmarkData = bookmarks.bookmarkData(for: destinationRoot)

            var editedPairs = syncFolderPairs
            editedPairs[index] = editedPair
            guard validateSyncFolders(
                originRoot: editedPair.originURL,
                destinationRoot: effectiveSyncDestinationRoot(for: editedPair, in: editedPairs)
            ) else {
                return
            }
            guard syncDestinationCollisionMessage(for: editedPairs) == nil else {
                statusMessage =
                    "Another enabled sync pair already targets the same destination folder. Rename one origin folder or choose a different destination."
                return
            }

            syncFolderPairs = editedPairs
            self.editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
            resetFolderSyncPlan()
            statusMessage = "Updated sync pair. Press Sync to run the next mirror pass."
            return
        }

        let nextPairs = syncFolderPairs + [candidatePair]
        guard validateSyncFolders(
            originRoot: candidatePair.originURL,
            destinationRoot: effectiveSyncDestinationRoot(for: candidatePair, in: nextPairs)
        ) else {
            return
        }

        if syncFolderPairs.contains(where: {
            $0.originPath == originPath && $0.destinationPath == destinationPath
        }) {
            statusMessage = "That sync pair is already in the list."
            return
        }

        guard syncDestinationCollisionMessage(for: nextPairs) == nil else {
            statusMessage =
                "Another enabled sync pair already targets the same destination folder. Rename one origin folder or choose a different destination."
            return
        }

        syncFolderPairs.append(candidatePair)
        syncDraftOriginRoot = nil
        syncDraftDestinationRoot = nil
        resetFolderSyncPlan()
        statusMessage = "Added sync pair. Press Sync to run the first mirror pass."
    }

    func editSyncFolderPair(_ pair: SyncFolderPair) {
        guard !isFolderSyncBusy else { return }
        editingSyncPairID = pair.id
        syncDraftOriginRoot = pair.originURL
        syncDraftDestinationRoot = pair.destinationURL
        statusMessage = "Editing sync pair. Change the folders, then save."
    }

    func cancelEditingSyncFolderPair() {
        guard !isFolderSyncBusy else { return }
        editingSyncPairID = nil
        syncDraftOriginRoot = nil
        syncDraftDestinationRoot = nil
        statusMessage = "Sync pair edit cancelled."
    }

    func removeSyncFolderPair(_ pair: SyncFolderPair) {
        guard !isFolderSyncBusy else { return }
        syncFolderPairs.removeAll { $0.id == pair.id }
        if currentSyncPairID == pair.id {
            currentSyncPairID = nil
        }
        if editingSyncPairID == pair.id {
            editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
        }
        resetFolderSyncPlan()
        statusMessage =
            syncFolderPairs.isEmpty ? "Removed the last sync pair." : "Removed sync pair."
    }

    func setSyncFolderPair(_ pair: SyncFolderPair, enabled: Bool) {
        guard !isFolderSyncBusy,
            let index = syncFolderPairs.firstIndex(where: { $0.id == pair.id })
        else {
            return
        }

        syncFolderPairs[index].isEnabled = enabled
        syncFolderPairs[index].state = enabled
            ? (syncAutoSyncEnabled ? .watching : .idle)
            : .disabled
        syncFolderPairs[index].lastMessage = enabled
            ? "Ready to sync."
            : "Paused. Automatic sync is disabled for this pair."
        resetFolderSyncPlan()
        statusMessage = enabled ? "Sync pair enabled." : "Sync pair paused."
    }

    func saveSyncFolderPairs() {
        guard canSaveSyncFolderPairs else {
            statusMessage = "Add at least one sync pair before saving a pair list."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Sync Pair List"
        panel.prompt = "Save Pair List"
        panel.allowedContentTypes = [SyncFolderPairListFile.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = syncDraftDestinationRoot ?? syncFolderPairs.first?.destinationURL ?? lastInputDirectoryURL()
        panel.nameFieldStringValue = defaultSyncFolderPairListFileName()

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let url = normalizedSyncFolderPairListFileURL(selectedURL)

        do {
            let data = try SyncFolderPairPersistence.encode(syncFolderPairs)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved \(syncFolderPairs.count) sync pair\(syncFolderPairs.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not save sync pair list: \(error.localizedDescription)"
        }
    }

    func loadSyncFolderPairsFromFile() {
        guard canLoadSyncFolderPairs else { return }

        let panel = NSOpenPanel()
        panel.title = "Load Sync Pair List"
        panel.prompt = "Load Pair List"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [SyncFolderPairListFile.contentType, .json]
        panel.directoryURL = syncDraftDestinationRoot ?? syncFolderPairs.first?.destinationURL ?? lastInputDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let loadedPairs = try normalizedLoadedSyncFolderPairs(from: data)
            guard validateLoadedSyncFolderPairs(loadedPairs) else { return }
            guard confirmReplacingSyncFolderPairs(withCount: loadedPairs.count) else { return }

            syncFolderPairs = loadedPairs
            editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
            resetFolderSyncPlan()
            statusMessage =
                "Loaded \(syncFolderPairs.count) sync pair\(syncFolderPairs.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not load sync pair list: \(error.localizedDescription)"
        }
    }

    func scanFolderSyncPlan() {
        folderSyncCoordinator.scan(configuration: folderSyncRunConfiguration)
    }

    func acknowledgeSyncSafetyMigration(keepDeletionEnabled: Bool) {
        settingsPersistence.set(
            FolderSyncSafetyPolicy.currentAcknowledgementVersion,
            forKey: DefaultsKey.syncSafetyAcknowledgementVersion
        )
        syncSafetyMigrationNeedsAcknowledgement = false
        syncDeleteDestinationItems = keepDeletionEnabled
        configureFolderSyncWatcher()
        statusMessage = keepDeletionEnabled
            ? "Sync safety changes acknowledged. Automatic plans with deletions will pause for review."
            : "Sync safety changes acknowledged. Destination deletion is off."
    }

    func requestSyncDestinationDeletion(_ enabled: Bool) {
        guard !isFolderSyncBusy else { return }
        guard enabled else {
            syncDeleteDestinationItems = false
            statusMessage = "Destination deletion is off."
            return
        }
        guard !syncDeleteDestinationItems else { return }

        guard folderSyncDeletionEnableConfirmationHandler() else {
            statusMessage = "Destination deletion remains off."
            return
        }

        if syncSafetyMigrationNeedsAcknowledgement {
            acknowledgeSyncSafetyMigration(keepDeletionEnabled: true)
        } else {
            syncDeleteDestinationItems = true
            statusMessage =
                "Destination deletion enabled. Automatic destructive plans will pause for review."
        }
    }

    func handleFolderSyncOriginChange() {
        folderSyncCoordinator.originDidChange()
    }

    func syncFoldersNow() {
        folderSyncCoordinator.syncNow(configuration: folderSyncRunConfiguration)
    }

    func cancelFolderSync() {
        folderSyncCoordinator.cancel()
    }

    func rollbackFolderSyncRun(_ runID: UUID) {
        folderSyncCoordinator.rollback(runID: runID)
    }

    func retryFolderSyncRun(_ runID: UUID) {
        folderSyncCoordinator.prepareRetry(
            runID: runID,
            configuration: folderSyncRunConfiguration
        )
    }

    func clearFolderSyncHistory() {
        folderSyncCoordinator.clearHistory()
    }
}
