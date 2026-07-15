import AppKit
import Foundation
import GPhilCoderCore

@MainActor
extension EncoderViewModel {
    func makeFolderSyncCoordinator() -> FolderSyncCoordinator {
        FolderSyncCoordinator(
            runExecutor: folderSyncRunExecutor,
            getIsBusy: { [weak self] in
                self?.isFolderSyncBusy ?? false
            },
            setPlan: { [weak self] plan in
                self?.syncPlan = plan
            },
            setScannedCounts: { [weak self] operations, copies, deletes, size in
                self?.syncScannedOperationCount = operations
                self?.syncScannedCopyCount = copies
                self?.syncScannedDeleteCount = deletes
                self?.syncScannedTotalSize = size
            },
            setProgress: { [weak self] progress in
                self?.syncProgress = progress
            },
            setCurrentPair: { [weak self] pairID in
                self?.currentSyncPairID = pairID
            },
            setScanning: { [weak self] isScanning in
                self?.isSyncScanning = isScanning
            },
            setSyncing: { [weak self] isSyncing in
                self?.isSyncing = isSyncing
            },
            setWatching: { [weak self] isWatching in
                self?.isFolderSyncWatching = isWatching
            },
            setAutomaticPlanAwaitingReview: { [weak self] awaitingReview in
                self?.syncAutomaticPlanAwaitingReview = awaitingReview
            },
            setRecovering: { [weak self] isRecovering in
                self?.isSyncRecovering = isRecovering
            },
            setHistory: { [weak self] history in
                self?.syncHistory = history
            },
            setRecoveryRecords: { [weak self] records in
                self?.syncRecoveryRecords = records
            },
            setStatusMessage: { [weak self] message in
                self?.statusMessage = message
            },
            markPair: { [weak self] id, state, message, lastSyncedAt in
                self?.markSyncPair(id, state: state, message: message, lastSyncedAt: lastSyncedAt)
            },
            collisionMessage: { [weak self] pairs in
                self?.syncDestinationCollisionMessage(for: pairs)
            },
            prepareFileAccess: { [weak self] pairs, triggeredAutomatically in
                self?.prepareFolderSyncFileAccess(
                    for: pairs,
                    triggeredAutomatically: triggeredAutomatically
                )
            },
            validateFolders: { [weak self] origin, destination, showsAlert in
                self?.validateSyncFolders(
                    originRoot: origin,
                    destinationRoot: destination,
                    showsAlert: showsAlert
                ) ?? false
            },
            releaseScopes: { [weak self] in
                self?.securityScopes.stopSync()
            },
            confirmDestructivePlan: { [weak self] summary in
                self?.folderSyncDestructiveConfirmationHandler(summary) ?? false
            },
            notifyCompletion: { [weak self] title, body in
                self?.notifyCompletionIfNeeded(title: title, body: body)
            },
            makeConfiguration: { [weak self] in
                self?.folderSyncRunConfiguration ?? .empty
            }
        )
    }

    var syncSelectedFileExtensions: Set<String>? {
        switch syncFileFilter {
        case .all:
            return nil
        case .audio:
            return MediaFileFilter.audio.fileExtensions
        case .video:
            return MediaFileFilter.video.fileExtensions
        case .custom:
            return Self.normalizedExtensionSet(from: syncCustomFileExtensions)
        }
    }

    var folderSyncRunConfiguration: FolderSyncRunConfiguration {
        FolderSyncRunConfiguration(
            pairs: syncFolderPairs,
            destinationLayout: syncDestinationLayout,
            deleteDestinationItems: syncDeleteDestinationItems,
            overwriteExisting: syncOverwriteExisting,
            includedFileExtensions: syncSelectedFileExtensions,
            autoSyncEnabled: !isLoadingPersistedSettings
                && syncAutoSyncEnabled
                && !syncSafetyMigrationNeedsAcknowledgement,
            watchOrigins: syncFolderPairs
                .filter(\.isEnabled)
                .compactMap { directoryURLIfExists(atPath: $0.originPath) },
            previewLimit: Self.syncPreviewLimit
        )
    }

    func prepareFolderSyncFileAccess(
        for pairs: [SyncFolderPair],
        triggeredAutomatically: Bool
    ) -> [SyncFolderPair]? {
        securityScopes.stopSync()

        var preparedPairs = pairs
        startFolderSyncSecurityScopes(for: preparedPairs)

        let pairsMissingBookmarks = preparedPairs.filter {
            $0.originBookmarkData == nil || $0.destinationBookmarkData == nil
        }
        guard !pairsMissingBookmarks.isEmpty else { return preparedPairs }

        guard !triggeredAutomatically else {
            securityScopes.stopSync()
            statusMessage = "Auto-sync skipped because loaded sync pairs need folder access authorization."
            return nil
        }

        guard let grantedRoots = requestFolderSyncAccess(for: pairsMissingBookmarks) else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because folder access was not authorized."
            return nil
        }

        securityScopes.startSync(grantedRoots)
        guard selectedSyncAccessRoots(grantedRoots, cover: pairsMissingBookmarks) else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because the selected folder does not contain every loaded origin and destination."
            return nil
        }

        let grantedBookmarks = grantedRoots.compactMap { root -> (url: URL, data: Data)? in
            guard let data = bookmarks.bookmarkData(for: root) else { return nil }
            return (root, data)
        }

        for index in preparedPairs.indices {
            if preparedPairs[index].originBookmarkData == nil {
                preparedPairs[index].originBookmarkData = bookmarks.bookmarkData(
                    for: preparedPairs[index].originURL,
                    in: grantedBookmarks
                )
            }
            if preparedPairs[index].destinationBookmarkData == nil {
                preparedPairs[index].destinationBookmarkData = bookmarks.bookmarkData(
                    for: preparedPairs[index].destinationURL,
                    in: grantedBookmarks
                )
            }
        }

        let stillMissingBookmarks = preparedPairs.contains {
            $0.originBookmarkData == nil || $0.destinationBookmarkData == nil
        }
        guard !stillMissingBookmarks else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because GPhil MediaFlow could not save folder authorization."
            return nil
        }

        updateStoredSyncPairs(with: preparedPairs)
        startFolderSyncSecurityScopes(for: preparedPairs)
        return preparedPairs
    }

    private func requestFolderSyncAccess(for pairs: [SyncFolderPair]) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Authorize Sync Folder Access"
        panel.prompt = "Authorize"
        panel.message =
            "GPhil MediaFlow needs permission to read and write the folders loaded from this sync pair list. Choose a parent folder that contains all listed origins and destinations, or choose the individual folders."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = commonFolderSyncAccessRoot(for: pairs) ?? pairs.first?.originURL

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func commonFolderSyncAccessRoot(for pairs: [SyncFolderPair]) -> URL? {
        let paths = pairs.flatMap { pair in
            [SecurityScopeManager.normalizedFilePath(pair.originURL),
             SecurityScopeManager.normalizedFilePath(pair.destinationURL)]
        }
        guard let firstPath = paths.first else { return nil }

        var commonComponents = URL(fileURLWithPath: firstPath, isDirectory: true).pathComponents
        for path in paths.dropFirst() {
            let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
            commonComponents = Array(zip(commonComponents, components).prefix { $0 == $1 }.map(\.0))
            guard !commonComponents.isEmpty else { return nil }
        }

        let commonPath = NSString.path(withComponents: commonComponents)
        return URL(fileURLWithPath: commonPath, isDirectory: true)
    }

    private func selectedSyncAccessRoots(_ roots: [URL], cover pairs: [SyncFolderPair]) -> Bool {
        for pair in pairs {
            guard roots.contains(where: { SecurityScopeManager.containsFileURL(pair.originURL, in: $0) }),
                roots.contains(where: { SecurityScopeManager.containsFileURL(pair.destinationURL, in: $0) })
            else {
                return false
            }
        }
        return true
    }

    /// Resolves persisted bookmarks and refreshes stale bookmark data before
    /// a scan or mutation run begins.
    private func startFolderSyncSecurityScopes(for pairs: [SyncFolderPair]) {
        var refreshedPairs = pairs
        var anyPairRefreshed = false

        let urls = pairs.flatMap { pair -> [URL] in
            guard let index = refreshedPairs.firstIndex(where: { $0.id == pair.id }) else {
                return [pair.originURL, pair.destinationURL]
            }
            let originURL = bookmarks.resolveSecurityScopedBookmark(
                pair.originBookmarkData,
                fallbackURL: pair.originURL
            ) { resolved in
                if let refreshed = self.bookmarks.bookmarkData(for: resolved) {
                    refreshedPairs[index].originBookmarkData = refreshed
                    anyPairRefreshed = true
                }
            }
            let destinationURL = bookmarks.resolveSecurityScopedBookmark(
                pair.destinationBookmarkData,
                fallbackURL: pair.destinationURL
            ) { resolved in
                if let refreshed = self.bookmarks.bookmarkData(for: resolved) {
                    refreshedPairs[index].destinationBookmarkData = refreshed
                    anyPairRefreshed = true
                }
            }
            return [originURL, destinationURL]
        }

        securityScopes.startSync(urls)
        if anyPairRefreshed {
            updateStoredSyncPairs(with: refreshedPairs)
        }
    }

    private func updateStoredSyncPairs(with preparedPairs: [SyncFolderPair]) {
        guard !preparedPairs.isEmpty else { return }
        var updatedPairs = syncFolderPairs
        for preparedPair in preparedPairs {
            guard let index = updatedPairs.firstIndex(where: { $0.id == preparedPair.id }) else { continue }
            updatedPairs[index] = preparedPair
        }
        syncFolderPairs = updatedPairs
    }

    func validateSyncFolders(
        originRoot: URL,
        destinationRoot: URL,
        showsAlert: Bool = true,
        createsDestinationDirectory: Bool = true
    ) -> Bool {
        let originComponents = originRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let destinationComponents =
            destinationRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard directoryURLIfExists(atPath: originRoot.path) != nil else {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Origin folder is missing",
                    detail: "Choose an existing origin folder before syncing."
                )
            }
            return false
        }

        if createsDestinationDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: destinationRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                if showsAlert {
                    showMediaCopyFolderAlert(
                        message: "Destination folder is unavailable",
                        detail: "GPhil MediaFlow could not create or open the destination folder: \(error.localizedDescription)"
                    )
                }
                return false
            }
        }

        if originComponents == destinationComponents {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Choose different folders",
                    detail:
                        "The sync origin and destination folders are the same. Choose a separate destination folder."
                )
            }
            return false
        }

        if destinationComponents.count > originComponents.count
            && Array(destinationComponents.prefix(originComponents.count)) == originComponents
        {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Destination is inside the origin",
                    detail:
                        "Choose a destination outside the origin tree so sync output is not scanned as new origin content."
                )
            }
            return false
        }

        if originComponents.count > destinationComponents.count
            && Array(originComponents.prefix(destinationComponents.count)) == destinationComponents
        {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Origin is inside the destination",
                    detail:
                        "Choose folders that do not contain each other so deletion mirroring cannot remove the origin tree."
                )
            }
            return false
        }

        return true
    }

    func validateLoadedSyncFolderPairs(_ pairs: [SyncFolderPair]) -> Bool {
        var seenPairs = Set<String>()
        for pair in pairs {
            let key = "\(pair.originPath)\n\(pair.destinationPath)"
            guard seenPairs.insert(key).inserted else {
                statusMessage =
                    "Could not load sync pair list: it contains duplicate origin and destination folders."
                return false
            }

            guard validateSyncFolders(
                originRoot: pair.originURL,
                destinationRoot: effectiveSyncDestinationRoot(for: pair, in: pairs),
                showsAlert: false,
                createsDestinationDirectory: false
            ) else {
                statusMessage =
                    "Could not load sync pair list: one or more origin folders are missing or folder paths are nested unsafely."
                return false
            }
        }

        if let collisionMessage = syncDestinationCollisionMessage(for: pairs) {
            statusMessage = "Could not load sync pair list: \(collisionMessage)"
            return false
        }

        return true
    }

    func confirmReplacingSyncFolderPairs(withCount newPairCount: Int) -> Bool {
        guard !syncFolderPairs.isEmpty else { return true }
        return folderSyncPairReplacementConfirmationHandler(
            syncFolderPairs.count,
            newPairCount
        )
    }

    func effectiveSyncDestinationRoot(
        for pair: SyncFolderPair,
        in pairs: [SyncFolderPair]? = nil
    ) -> URL {
        let resolutionPairs = pairs ?? syncDestinationResolutionPairs(for: pair)
        return pair.effectiveDestinationURL(
            layout: syncDestinationLayout,
            allPairs: resolutionPairs
        )
    }

    private func syncDestinationResolutionPairs(for pair: SyncFolderPair) -> [SyncFolderPair] {
        let enabledPairs = syncFolderPairs.filter(\.isEnabled)
        if pair.isEnabled {
            return enabledPairs
        }
        return enabledPairs + [pair]
    }

    func syncDestinationCollisionMessage(for pairs: [SyncFolderPair]) -> String? {
        var seenPaths: [String: SyncFolderPair] = [:]
        for pair in pairs where pair.isEnabled {
            let target = effectiveSyncDestinationRoot(for: pair, in: pairs)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if let existing = seenPaths[target], existing.id != pair.id {
                return
                    "Sync pairs \"\(existing.originURL.lastPathComponent)\" and \"\(pair.originURL.lastPathComponent)\" target the same destination folder. Use different destination folders or rename one origin folder."
            }
            seenPaths[target] = pair
        }
        return nil
    }

    func resetFolderSyncPlan() {
        guard !isLoadingPersistedSettings, !isFolderSyncBusy else { return }
        folderSyncCoordinator.invalidateReviewedPlan()
    }

    func markSyncPair(
        _ id: UUID,
        state: SyncPairState,
        message: String,
        lastSyncedAt: Date? = nil
    ) {
        guard let index = syncFolderPairs.firstIndex(where: { $0.id == id }) else { return }
        isUpdatingSyncPairStatus = true
        defer {
            isUpdatingSyncPairStatus = false
            if lastSyncedAt != nil {
                persistSyncFolderPairs()
            }
        }
        syncFolderPairs[index].state = syncFolderPairs[index].isEnabled ? state : .disabled
        syncFolderPairs[index].lastMessage = message
        if let lastSyncedAt {
            syncFolderPairs[index].lastSyncedAt = lastSyncedAt
        }
    }

    func configureFolderSyncWatcher() {
        folderSyncCoordinator.configureWatcher(configuration: folderSyncRunConfiguration)
    }

    func persistSyncFolderPairs() {
        guard !isLoadingPersistedSettings else { return }
        do {
            let data = try SyncFolderPairPersistence.encode(syncFolderPairs)
            settingsPersistence.set(data, forKey: DefaultsKey.syncFolderPairs)
        } catch {
            statusMessage = "Could not save sync pairs: \(error.localizedDescription)"
        }
    }

    func loadSyncFolderPairs() {
        guard let data = settingsPersistence.data(forKey: DefaultsKey.syncFolderPairs) else {
            return
        }

        do {
            syncFolderPairs = try normalizedLoadedSyncFolderPairs(from: data)
        } catch {
            statusMessage = "Could not read saved sync pairs: \(error.localizedDescription)"
        }
    }

    func normalizedLoadedSyncFolderPairs(from data: Data) throws -> [SyncFolderPair] {
        let pairs = try SyncFolderPairPersistence.decode(data)
        return pairs.map { pair in
            var pair = pair
            if !pair.isEnabled {
                pair.state = .disabled
            } else {
                pair.state = syncAutoSyncEnabled ? .watching : .idle
            }
            return pair
        }
    }

    func defaultSyncFolderPairListFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhil MediaFlow Sync Pairs \(formatter.string(from: Date())).\(SyncFolderPairListFile.fileExtension)"
    }

    func normalizedSyncFolderPairListFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(SyncFolderPairListFile.fileExtension) : url
    }
}
