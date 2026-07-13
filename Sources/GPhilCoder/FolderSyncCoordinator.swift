import Foundation
import GPhilCoderCore

struct FolderSyncRunConfiguration {
    let pairs: [SyncFolderPair]
    let destinationLayout: SyncDestinationLayout
    let deleteDestinationItems: Bool
    let overwriteExisting: Bool
    let includedFileExtensions: Set<String>?
    let autoSyncEnabled: Bool
    let watchOrigins: [URL]
    let previewLimit: Int

    static let empty = FolderSyncRunConfiguration(
        pairs: [],
        destinationLayout: .originSubfolder,
        deleteDestinationItems: false,
        overwriteExisting: true,
        includedFileExtensions: nil,
        autoSyncEnabled: false,
        watchOrigins: [],
        previewLimit: 0
    )
}

private struct FolderSyncReviewedConfiguration: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        let id: UUID
        let originPath: String
        let destinationPath: String
    }

    let pairs: [Pair]
    let destinationLayout: SyncDestinationLayout
    let deleteDestinationItems: Bool
    let overwriteExisting: Bool
    let includedFileExtensions: [String]?

    init(configuration: FolderSyncRunConfiguration) {
        pairs = configuration.pairs.filter(\.isEnabled).map {
            Pair(
                id: $0.id,
                originPath: $0.originURL.standardizedFileURL.path,
                destinationPath: $0.destinationURL.standardizedFileURL.path
            )
        }
        destinationLayout = configuration.destinationLayout
        deleteDestinationItems = configuration.deleteDestinationItems
        overwriteExisting = configuration.overwriteExisting
        includedFileExtensions = configuration.includedFileExtensions.map { $0.sorted() }
    }
}

@MainActor
final class FolderSyncCoordinator {
    private static let autoDebounceNanoseconds: UInt64 = 1_250_000_000

    private let runExecutor: FolderSyncRunExecutor?
    private let getIsBusy: @MainActor () -> Bool
    private let setPlan: @MainActor (FolderSyncBatchPlan?) -> Void
    private let setScannedCounts: @MainActor (_ operations: Int, _ copies: Int, _ deletes: Int, _ size: Int64) -> Void
    private let setProgress: @MainActor (FolderSyncProgress?) -> Void
    private let setCurrentPair: @MainActor (UUID?) -> Void
    private let setScanning: @MainActor (Bool) -> Void
    private let setSyncing: @MainActor (Bool) -> Void
    private let setWatching: @MainActor (Bool) -> Void
    private let setAutomaticPlanAwaitingReview: @MainActor (Bool) -> Void
    private let setRecovering: @MainActor (Bool) -> Void
    private let setHistory: @MainActor ([FolderSyncHistoryRun]) -> Void
    private let setRecoveryRecords: @MainActor ([FolderSyncRecoveryRecord]) -> Void
    private let setStatusMessage: @MainActor (String) -> Void
    private let markPair: @MainActor (_ id: UUID, _ state: SyncPairState, _ message: String, _ lastSyncedAt: Date?) -> Void
    private let collisionMessage: @MainActor ([SyncFolderPair]) -> String?
    private let prepareFileAccess: @MainActor (_ pairs: [SyncFolderPair], _ triggeredAutomatically: Bool) -> [SyncFolderPair]?
    private let validateFolders: @MainActor (_ origin: URL, _ destination: URL, _ showsAlert: Bool) -> Bool
    private let releaseScopes: @MainActor () -> Void
    private let confirmDestructivePlan: @MainActor (FolderSyncDestructiveSummary) -> Bool
    private let notifyCompletion: @MainActor (_ title: String, _ body: String) -> Void
    private let makeConfiguration: @MainActor () -> FolderSyncRunConfiguration

    private var folderSyncTask: Task<Void, Never>?
    private var folderSyncAutoTask: Task<Void, Never>?
    private var folderSyncWatcher: FolderSyncWatcher?
    private var folderSyncPendingAfterCurrentRun = false
    private var reviewedPlan: FolderSyncBatchPlan?
    private var reviewedConfiguration: FolderSyncReviewedConfiguration?
    private var reviewedTrigger: FolderSyncHistoryTrigger = .manual
    private var automaticPlanAwaitingReview = false
    private var isRollingBack = false

    init(
        runExecutor: FolderSyncRunExecutor?,
        getIsBusy: @escaping @MainActor () -> Bool,
        setPlan: @escaping @MainActor (FolderSyncBatchPlan?) -> Void,
        setScannedCounts: @escaping @MainActor (_ operations: Int, _ copies: Int, _ deletes: Int, _ size: Int64) -> Void,
        setProgress: @escaping @MainActor (FolderSyncProgress?) -> Void,
        setCurrentPair: @escaping @MainActor (UUID?) -> Void,
        setScanning: @escaping @MainActor (Bool) -> Void,
        setSyncing: @escaping @MainActor (Bool) -> Void,
        setWatching: @escaping @MainActor (Bool) -> Void,
        setAutomaticPlanAwaitingReview: @escaping @MainActor (Bool) -> Void,
        setRecovering: @escaping @MainActor (Bool) -> Void,
        setHistory: @escaping @MainActor ([FolderSyncHistoryRun]) -> Void,
        setRecoveryRecords: @escaping @MainActor ([FolderSyncRecoveryRecord]) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        markPair: @escaping @MainActor (_ id: UUID, _ state: SyncPairState, _ message: String, _ lastSyncedAt: Date?) -> Void,
        collisionMessage: @escaping @MainActor ([SyncFolderPair]) -> String?,
        prepareFileAccess: @escaping @MainActor (_ pairs: [SyncFolderPair], _ triggeredAutomatically: Bool) -> [SyncFolderPair]?,
        validateFolders: @escaping @MainActor (_ origin: URL, _ destination: URL, _ showsAlert: Bool) -> Bool,
        releaseScopes: @escaping @MainActor () -> Void,
        confirmDestructivePlan: @escaping @MainActor (FolderSyncDestructiveSummary) -> Bool,
        notifyCompletion: @escaping @MainActor (_ title: String, _ body: String) -> Void,
        makeConfiguration: @escaping @MainActor () -> FolderSyncRunConfiguration
    ) {
        self.runExecutor = runExecutor
        self.getIsBusy = getIsBusy
        self.setPlan = setPlan
        self.setScannedCounts = setScannedCounts
        self.setProgress = setProgress
        self.setCurrentPair = setCurrentPair
        self.setScanning = setScanning
        self.setSyncing = setSyncing
        self.setWatching = setWatching
        self.setAutomaticPlanAwaitingReview = setAutomaticPlanAwaitingReview
        self.setRecovering = setRecovering
        self.setHistory = setHistory
        self.setRecoveryRecords = setRecoveryRecords
        self.setStatusMessage = setStatusMessage
        self.markPair = markPair
        self.collisionMessage = collisionMessage
        self.prepareFileAccess = prepareFileAccess
        self.validateFolders = validateFolders
        self.releaseScopes = releaseScopes
        self.confirmDestructivePlan = confirmDestructivePlan
        self.notifyCompletion = notifyCompletion
        self.makeConfiguration = makeConfiguration
    }

    func scan(configuration: FolderSyncRunConfiguration) {
        run(syncAfterScan: false, triggeredAutomatically: false, configuration: configuration)
    }

    func syncNow(configuration: FolderSyncRunConfiguration) {
        applyReviewedPlan(configuration: configuration)
    }

    func prepareRetry(runID: UUID, configuration: FolderSyncRunConfiguration) {
        guard !getIsBusy() else { return }
        guard let runExecutor,
            let priorRun = runExecutor.historyRuns.first(where: { $0.id == runID })
        else {
            setStatusMessage("That Folder Sync run is no longer available in history.")
            return
        }
        let retryKeys = Set(
            priorRun.retryCandidates.map {
                FolderSyncBatchOperationKey(
                    pairID: $0.pairID,
                    operationID: $0.operationID
                )
            }
        )
        guard !retryKeys.isEmpty else {
            setStatusMessage("That Folder Sync run has no eligible failed or cancelled changes.")
            return
        }

        var pairs = configuration.pairs.filter(\.isEnabled)
        guard !pairs.isEmpty else {
            setStatusMessage("Restore the run's folder pairs before retrying its changes.")
            return
        }
        if let collisionMessage = collisionMessage(pairs) {
            setStatusMessage(collisionMessage)
            return
        }
        guard let authorizedPairs = prepareFileAccess(pairs, false) else { return }
        pairs = authorizedPairs
        for pair in pairs {
            let destination = pair.effectiveDestinationURL(
                layout: configuration.destinationLayout,
                allPairs: pairs
            )
            guard validateFolders(pair.originURL, destination, true) else {
                releaseScopes()
                return
            }
        }

        invalidateReviewedPlan()
        setScanning(true)
        setStatusMessage("Checking eligible failed and cancelled Sync changes...")
        folderSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let currentPlan = try await self.buildBatchPlan(
                    pairs: pairs,
                    configuration: configuration
                )
                try Task.checkCancellation()
                let retryPlan = currentPlan.retainingOperations(with: retryKeys)
                self.reviewedPlan = retryPlan
                self.reviewedConfiguration = FolderSyncReviewedConfiguration(
                    configuration: configuration
                )
                self.reviewedTrigger = .retry
                self.setPlan(retryPlan)
                self.setScannedCounts(
                    retryPlan.operationCount,
                    retryPlan.copyCount,
                    retryPlan.deleteCount,
                    retryPlan.totalCopyBytes
                )
                self.setScanning(false)
                self.setCurrentPair(nil)
                self.folderSyncTask = nil
                self.releaseScopes()
                if !retryPlan.isComplete {
                    self.setStatusMessage(Self.incompletePlanStatusMessage(retryPlan))
                } else {
                    self.setStatusMessage(
                        retryPlan.hasWork
                            ? "Found \(retryPlan.operationCount) eligible retry change\(retryPlan.operationCount == 1 ? "" : "s"). Review the retry plan, then apply it."
                            : "No eligible failed or cancelled changes still need work."
                    )
                }
            } catch is CancellationError {
                self.finishCancelledTask()
            } catch {
                self.setScanning(false)
                self.setCurrentPair(nil)
                self.folderSyncTask = nil
                self.releaseScopes()
                self.setStatusMessage(
                    "Could not prepare the Folder Sync retry plan: \(error.localizedDescription)"
                )
            }
        }
    }

    func invalidateReviewedPlan() {
        reviewedPlan = nil
        reviewedConfiguration = nil
        reviewedTrigger = .manual
        automaticPlanAwaitingReview = false
        setAutomaticPlanAwaitingReview(false)
        setPlan(nil)
        setScannedCounts(0, 0, 0, 0)
        setProgress(nil)
    }

    func cancel() {
        guard getIsBusy() else { return }
        guard !isRollingBack else {
            setStatusMessage("Folder Sync rollback is already restoring retained items.")
            return
        }
        folderSyncTask?.cancel()
        folderSyncAutoTask?.cancel()
        folderSyncAutoTask = nil
        folderSyncPendingAfterCurrentRun = false
        setStatusMessage("Cancelling folder sync after the current item finishes...")
    }

    func rollback(runID: UUID) {
        guard !getIsBusy() else { return }
        guard let runExecutor else {
            setStatusMessage("Folder Sync recovery is unavailable. No files were changed.")
            return
        }

        isRollingBack = true
        setRecovering(true)
        setStatusMessage("Rolling back recoverable Folder Sync changes...")
        folderSyncTask = Task { [weak self] in
            guard let self else { return }
            let activeRecords = await runExecutor.recoveryRecords(runID: runID)
            guard !activeRecords.isEmpty else {
                self.isRollingBack = false
                self.setRecovering(false)
                self.folderSyncTask = nil
                self.setStatusMessage(
                    "No active recovery records remain for this Folder Sync run."
                )
                return
            }

            let accessPairs = self.recoveryAccessPairs(
                runID: runID,
                records: activeRecords,
                runExecutor: runExecutor
            )
            if !accessPairs.isEmpty,
                self.prepareFileAccess(accessPairs, false) == nil
            {
                self.isRollingBack = false
                self.setRecovering(false)
                self.folderSyncTask = nil
                return
            }

            let report = await runExecutor.rollback(runID: runID)
            let historyError: Error?
            do {
                _ = try runExecutor.recordRollback(runID: runID, report: report)
                historyError = nil
            } catch {
                historyError = error
            }
            let records = await runExecutor.recoveryRecords()
            self.setRecoveryRecords(records)
            self.setHistory(runExecutor.historyRuns)
            self.isRollingBack = false
            self.setRecovering(false)
            self.folderSyncTask = nil
            self.releaseScopes()
            let rollbackMessage = Self.folderSyncRollbackStatusMessage(report)
            if let historyError {
                self.setStatusMessage(
                    "\(rollbackMessage) The rollback result could not be saved to history: \(historyError.localizedDescription)"
                )
            } else {
                self.setStatusMessage(rollbackMessage)
            }
        }
    }

    private func recoveryAccessPairs(
        runID: UUID,
        records: [FolderSyncRecoveryRecord],
        runExecutor: FolderSyncRunExecutor
    ) -> [SyncFolderPair] {
        if let historyRun = runExecutor.historyRuns.first(where: { $0.id == runID }) {
            let currentPairsByID = Dictionary(
                uniqueKeysWithValues: makeConfiguration().pairs.map { ($0.id, $0) }
            )
            return historyRun.pairs.map { snapshot in
                currentPairsByID[snapshot.id]
                    ?? SyncFolderPair(
                        id: snapshot.id,
                        originPath: snapshot.originPath,
                        destinationPath: snapshot.destinationPath
                    )
            }
        }

        let currentConfiguration = makeConfiguration()
        let currentPairs = currentConfiguration.pairs
        return Dictionary(grouping: records, by: \.destinationRootPath)
            .keys
            .sorted()
            .map { path in
                currentPairs.first { pair in
                    pair.effectiveDestinationURL(
                        layout: currentConfiguration.destinationLayout,
                        allPairs: currentPairs
                    ).standardizedFileURL.path == path
                } ?? SyncFolderPair(originPath: path, destinationPath: path)
            }
    }

    func clearHistory() {
        guard !getIsBusy() else { return }
        guard let runExecutor else {
            setStatusMessage("Folder Sync history is unavailable.")
            return
        }
        do {
            try runExecutor.clearHistory()
            setHistory([])
            setStatusMessage(
                "Cleared Folder Sync history metadata. Recoverable files and recovery records were kept."
            )
        } catch {
            setStatusMessage("Could not clear Folder Sync history: \(error.localizedDescription)")
        }
    }

    func configureWatcher(configuration: FolderSyncRunConfiguration) {
        folderSyncWatcher?.stop()
        folderSyncWatcher = nil
        setWatching(false)
        guard configuration.autoSyncEnabled else { return }
        guard !configuration.watchOrigins.isEmpty else { return }

        let watcher = FolderSyncWatcher(urls: configuration.watchOrigins) { [weak self] in
            DispatchQueue.main.async {
                self?.originDidChange()
            }
        }
        guard watcher.isWatching else { return }

        folderSyncWatcher = watcher
        setWatching(true)
    }

    func originDidChange() {
        guard !automaticPlanAwaitingReview else {
            setStatusMessage(
                "A folder changed while an automatic destructive plan awaits review. Review it or scan again before applying."
            )
            return
        }
        scheduleAutomaticFolderSync()
    }

    private func applyReviewedPlan(configuration: FolderSyncRunConfiguration) {
        guard !getIsBusy() else { return }
        guard runExecutor != nil else {
            setStatusMessage("Folder Sync recovery is unavailable. No files were changed.")
            return
        }
        guard let reviewedPlan, let reviewedConfiguration else {
            setStatusMessage("Scan and review the folder sync plan before applying it.")
            scan(configuration: configuration)
            return
        }
        guard reviewedPlan.isComplete else {
            let failedPairCount = reviewedPlan.planningFailures.count
            setStatusMessage(
                "The reviewed folder sync plan is incomplete because \(failedPairCount) pair\(failedPairCount == 1 ? "" : "s") could not be scanned. Scan again before applying."
            )
            return
        }
        guard reviewedConfiguration == FolderSyncReviewedConfiguration(configuration: configuration) else {
            invalidateReviewedPlan()
            setStatusMessage("Folder sync settings changed. Scan and review a new plan before applying.")
            return
        }

        var pairs = configuration.pairs.filter(\.isEnabled)
        guard !pairs.isEmpty else {
            invalidateReviewedPlan()
            setStatusMessage("Add at least one enabled folder pair before syncing.")
            return
        }
        if let collisionMessage = collisionMessage(pairs) {
            setStatusMessage(collisionMessage)
            return
        }
        guard let authorizedPairs = prepareFileAccess(pairs, false) else { return }
        pairs = authorizedPairs
        for pair in pairs {
            let destination = pair.effectiveDestinationURL(
                layout: configuration.destinationLayout,
                allPairs: pairs
            )
            guard validateFolders(pair.originURL, destination, true) else {
                releaseScopes()
                markPair(pair.id, .failed, "Origin and destination folders are not valid.", nil)
                return
            }
        }

        setScanning(true)
        setSyncing(false)
        setProgress(nil)
        setStatusMessage("Checking the reviewed folder sync plan for changes...")
        folderSyncTask = Task { [weak self] in
            await self?.revalidateAndApply(
                reviewedPlan: reviewedPlan,
                pairs: pairs,
                configuration: configuration
            )
        }
    }

    private func revalidateAndApply(
        reviewedPlan: FolderSyncBatchPlan,
        pairs: [SyncFolderPair],
        configuration: FolderSyncRunConfiguration
    ) async {
        do {
            let currentPlan = try await buildBatchPlan(pairs: pairs, configuration: configuration)
            try Task.checkCancellation()
            guard currentPlan.isComplete else {
                self.reviewedPlan = currentPlan
                self.reviewedConfiguration = FolderSyncReviewedConfiguration(
                    configuration: configuration
                )
                setPlan(currentPlan)
                setScannedCounts(
                    currentPlan.operationCount,
                    currentPlan.copyCount,
                    currentPlan.deleteCount,
                    currentPlan.totalCopyBytes
                )
                setScanning(false)
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage(Self.incompletePlanStatusMessage(currentPlan))
                return
            }
            let currentReviewedOperations: FolderSyncBatchPlan
            if reviewedTrigger == .retry {
                currentReviewedOperations = currentPlan.retainingOperations(
                    with: Set(reviewedPlan.operations.map(\.key))
                )
            } else {
                currentReviewedOperations = currentPlan
            }
            guard reviewedPlan.hasSameOperations(as: currentReviewedOperations) else {
                setScanning(false)
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                invalidateReviewedPlan()
                setStatusMessage(
                    "Folder contents changed after the plan was reviewed. Nothing was synced; scan again."
                )
                return
            }

            setScanning(false)
            guard reviewedPlan.hasWork else {
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage("All enabled sync pairs are already current.")
                return
            }

            let destructiveSummary = reviewedPlan.destructiveSummary(
                overwriteExisting: configuration.overwriteExisting
            )
            if destructiveSummary.hasDestructiveOperations,
                !confirmDestructivePlan(destructiveSummary)
            {
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage("Folder sync cancelled. The reviewed plan was not changed.")
                return
            }

            setSyncing(true)
            setStatusMessage(
                "Applying \(reviewedPlan.operationCount) reviewed change\(reviewedPlan.operationCount == 1 ? "" : "s")..."
            )
            let result = try await applyFolderSyncPlan(
                reviewedPlan,
                trigger: reviewedTrigger,
                configuration: configuration
            )

            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            invalidateReviewedPlan()
            let completionMessage = Self.folderSyncResultStatusMessage(result)
            setStatusMessage(completionMessage)
            notifyCompletion("Folder sync finished", completionMessage)
            runPendingFolderSyncIfNeeded()
        } catch is CancellationError {
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Folder sync cancelled.")
        } catch {
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Could not apply the reviewed folder sync plan: \(error.localizedDescription)")
        }
    }

    private func run(
        syncAfterScan: Bool,
        triggeredAutomatically: Bool,
        configuration: FolderSyncRunConfiguration
    ) {
        guard runExecutor != nil else {
            setStatusMessage("Folder Sync recovery is unavailable. No files were changed.")
            return
        }
        if triggeredAutomatically, automaticPlanAwaitingReview {
            setStatusMessage(
                "Automatic folder sync remains paused until its destructive plan is reviewed."
            )
            return
        }
        var pairs = configuration.pairs.filter(\.isEnabled)
        guard !pairs.isEmpty else {
            setStatusMessage("Add at least one enabled folder pair before syncing.")
            return
        }

        guard !getIsBusy() else {
            if triggeredAutomatically {
                folderSyncPendingAfterCurrentRun = true
            }
            return
        }

        if let collisionMessage = collisionMessage(pairs) {
            setStatusMessage(collisionMessage)
            return
        }

        guard let authorizedPairs = prepareFileAccess(pairs, triggeredAutomatically) else {
            return
        }
        pairs = authorizedPairs

        let destinationLayout = configuration.destinationLayout

        for pair in pairs {
            let effectiveDestinationRoot = pair.effectiveDestinationURL(
                layout: destinationLayout,
                allPairs: pairs
            )
            guard validateFolders(pair.originURL, effectiveDestinationRoot, !triggeredAutomatically) else {
                markPair(
                    pair.id,
                    .failed,
                    "Origin and destination folders are not valid.",
                    nil
                )
                releaseScopes()
                return
            }
        }

        folderSyncTask?.cancel()
        reviewedPlan = nil
        reviewedConfiguration = nil
        reviewedTrigger = triggeredAutomatically ? .automatic : .manual
        automaticPlanAwaitingReview = false
        setAutomaticPlanAwaitingReview(false)
        setPlan(nil)
        setScannedCounts(0, 0, 0, 0)
        setProgress(nil)
        setCurrentPair(nil)
        setScanning(true)
        setSyncing(false)
        setStatusMessage(
            "Scanning \(pairs.count) folder sync pair\(pairs.count == 1 ? "" : "s")..."
        )

        folderSyncTask = Task { [weak self] in
            await self?.runTask(
                pairs: pairs,
                syncAfterScan: syncAfterScan,
                triggeredAutomatically: triggeredAutomatically,
                configuration: configuration
            )
        }
    }

    private func runTask(
        pairs: [SyncFolderPair],
        syncAfterScan: Bool,
        triggeredAutomatically: Bool,
        configuration: FolderSyncRunConfiguration
    ) async {
        do {
            let batchPlan = try await buildBatchPlan(pairs: pairs, configuration: configuration)
            try Task.checkCancellation()

            reviewedPlan = batchPlan
            reviewedConfiguration = FolderSyncReviewedConfiguration(configuration: configuration)
            reviewedTrigger = triggeredAutomatically ? .automatic : .manual
            setPlan(batchPlan)
            setScannedCounts(
                batchPlan.operationCount,
                batchPlan.copyCount,
                batchPlan.deleteCount,
                batchPlan.totalCopyBytes
            )
            setScanning(false)

            guard batchPlan.isComplete else {
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage(Self.incompletePlanStatusMessage(batchPlan))
                return
            }

            if !batchPlan.hasWork, let runExecutor {
                _ = try runExecutor.recordNoChange(
                    plan: batchPlan,
                    trigger: reviewedTrigger,
                    configuration: configuration
                )
                setHistory(runExecutor.historyRuns)
            }

            if triggeredAutomatically, batchPlan.deleteCount > 0 {
                automaticPlanAwaitingReview = true
                setAutomaticPlanAwaitingReview(true)
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage(
                    "Automatic folder sync paused. Review all \(batchPlan.operationCount) changes before applying because the plan contains \(batchPlan.deleteCount) deletion\(batchPlan.deleteCount == 1 ? "" : "s")."
                )
                return
            }

            guard syncAfterScan else {
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage(
                    batchPlan.operationCount == 0
                        ? "All enabled sync pairs are already current."
                        : "Found \(batchPlan.operationCount) pending sync change\(batchPlan.operationCount == 1 ? "" : "s"). Review the plan, then apply it."
                )
                return
            }

            guard batchPlan.operationCount > 0 else {
                setCurrentPair(nil)
                folderSyncTask = nil
                let completionMessage = "All enabled sync pairs are already current."
                setStatusMessage(completionMessage)
                if !triggeredAutomatically {
                    notifyCompletion("Folder sync finished", completionMessage)
                }
                releaseScopes()
                runPendingFolderSyncIfNeeded()
                return
            }

            setSyncing(true)
            setStatusMessage("Syncing \(batchPlan.operationCount) change\(batchPlan.operationCount == 1 ? "" : "s")...")
            let result = try await applyFolderSyncPlan(
                batchPlan,
                trigger: reviewedTrigger,
                configuration: configuration
            )

            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            invalidateReviewedPlan()
            let completionMessage = Self.folderSyncResultStatusMessage(result)
            setStatusMessage(completionMessage)
            notifyCompletion("Folder sync finished", completionMessage)
            runPendingFolderSyncIfNeeded()
        } catch is CancellationError {
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Folder sync cancelled.")
        } catch {
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Could not run folder sync: \(error.localizedDescription)")
        }
    }

    private func buildBatchPlan(
        pairs: [SyncFolderPair],
        configuration: FolderSyncRunConfiguration
    ) async throws -> FolderSyncBatchPlan {
        var pairPlans: [FolderSyncPairPlan] = []
        var planningFailures: [FolderSyncPairPlanningFailure] = []
        for pair in pairs {
            try Task.checkCancellation()
            setCurrentPair(pair.id)
            markPair(pair.id, .syncing, "Scanning...", nil)
            let effectiveDestinationRoot = pair.effectiveDestinationURL(
                layout: configuration.destinationLayout,
                allPairs: pairs
            )
            let worker = Task.detached(priority: .userInitiated) {
                try FolderSyncPlanner.buildPlan(
                    originRoot: pair.originURL,
                    destinationRoot: effectiveDestinationRoot,
                    syncDeletes: configuration.deleteDestinationItems,
                    includedFileExtensions: configuration.includedFileExtensions
                )
            }
            let plan: FolderSyncPlan
            do {
                plan = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let errorDescription = error.localizedDescription
                planningFailures.append(
                    FolderSyncPairPlanningFailure(
                        pairID: pair.id,
                        pairTitle: pair.displayTitle,
                        originRoot: pair.originURL,
                        destinationRoot: effectiveDestinationRoot,
                        errorDescription: errorDescription
                    )
                )
                markPair(
                    pair.id,
                    .failed,
                    "Could not scan: \(errorDescription)",
                    nil
                )
                continue
            }
            pairPlans.append(
                FolderSyncPairPlan(
                    pairID: pair.id,
                    pairTitle: pair.displayTitle,
                    plan: plan
                )
            )
            let message = plan.hasWork
                ? "\(plan.operationCount) pending change\(plan.operationCount == 1 ? "" : "s")."
                : "Already in sync."
            markPair(pair.id, .watching, message, nil)
        }
        return FolderSyncBatchPlan(
            pairPlans: pairPlans,
            planningFailures: planningFailures
        )
    }

    private func applyFolderSyncPlan(
        _ plan: FolderSyncBatchPlan,
        trigger: FolderSyncHistoryTrigger,
        configuration: FolderSyncRunConfiguration
    ) async throws -> FolderSyncRunResult {
        guard let runExecutor else {
            throw CocoaError(.fileNoSuchFile)
        }

        do {
            let outcome = try await runExecutor.execute(
                plan: plan,
                trigger: trigger,
                configuration: configuration
            ) { [weak self] update in
                guard let self else { return }
                let result = update.result
                self.setCurrentPair(update.operation.pairID)
                self.markPair(
                    update.operation.pairID,
                    .syncing,
                    "Applying reviewed Sync changes...",
                    nil
                )
                let progress = FolderSyncProgress(
                    completed: update.completed,
                    total: plan.operationCount,
                    copied: result.copied,
                    deleted: result.deleted,
                    skipped: result.skipped,
                    failed: result.failed,
                    copiedBytes: update.copiedBytes,
                    totalBytes: plan.totalCopyBytes,
                    startedAt: update.startedAt,
                    updatedAt: Date(),
                    currentPath: update.operation.operation.relativePath
                )
                self.setProgress(progress)
                self.setHistory(runExecutor.historyRuns)
                let speedDetail = progress.bytesPerSecond
                    .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
                self.setStatusMessage(
                    "Synced \(update.completed) of \(plan.operationCount). Copied \(result.copied), deleted \(result.deleted), failed \(result.failed)\(speedDetail)."
                )
            }
            setHistory(runExecutor.historyRuns)
            setRecoveryRecords(await runExecutor.recoveryRecords())
            publishPairResults(outcome.historyRun, plan: plan)
            return outcome.result
        } catch {
            setHistory(runExecutor.historyRuns)
            setRecoveryRecords(await runExecutor.recoveryRecords())
            throw error
        }
    }

    private func publishPairResults(
        _ run: FolderSyncHistoryRun,
        plan: FolderSyncBatchPlan
    ) {
        for pairPlan in plan.pairPlans {
            let items = run.items.filter { $0.pairID == pairPlan.pairID }
            let failed = items.count { $0.outcome == .failed }
            let cancelled = items.count { $0.outcome == .cancelled }
            let completed = items.count - cancelled
            let state: SyncPairState = failed > 0 || cancelled > 0 ? .failed : .succeeded
            let message: String
            if cancelled > 0 {
                message = "Cancelled after \(completed) of \(items.count) changes."
            } else if failed > 0 {
                message = "Finished with \(failed) failed change\(failed == 1 ? "" : "s")."
            } else if items.isEmpty {
                message = "Already in sync."
            } else {
                message = "Synced \(items.count) change\(items.count == 1 ? "" : "s")."
            }
            markPair(pairPlan.pairID, state, message, Date())
        }
    }

    private func scheduleAutomaticFolderSync() {
        let configuration = makeConfiguration()
        guard configuration.autoSyncEnabled, !configuration.pairs.filter(\.isEnabled).isEmpty else {
            return
        }
        folderSyncAutoTask?.cancel()
        folderSyncAutoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.run(
                    syncAfterScan: true,
                    triggeredAutomatically: true,
                    configuration: self.makeConfiguration()
                )
            }
        }
    }

    private func finishCancelledTask() {
        setScanning(false)
        setSyncing(false)
        setCurrentPair(nil)
        folderSyncTask = nil
        releaseScopes()
        setStatusMessage("Folder sync cancelled.")
    }

    private func runPendingFolderSyncIfNeeded() {
        guard folderSyncPendingAfterCurrentRun else { return }
        folderSyncPendingAfterCurrentRun = false
        scheduleAutomaticFolderSync()
    }

    private static func folderSyncRollbackStatusMessage(
        _ report: FolderSyncRollbackReport
    ) -> String {
        guard !report.items.isEmpty else {
            return "No active recovery records remain for this Folder Sync run."
        }
        var parts = ["Folder Sync rollback finished", "\(report.restored) restored"]
        if report.skipped > 0 {
            parts.append("\(report.skipped) skipped")
        }
        if report.failed > 0 {
            parts.append("\(report.failed) failed")
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func incompletePlanStatusMessage(_ plan: FolderSyncBatchPlan) -> String {
        let count = plan.planningFailures.count
        return "Could not scan \(count) folder sync pair\(count == 1 ? "" : "s"). The plan is incomplete, so no changes can be applied."
    }

    private static func folderSyncResultStatusMessage(_ result: FolderSyncRunResult) -> String {
        if result.cancelled {
            return "Folder sync cancelled after \(result.copied) copied and \(result.deleted) deleted."
        }
        if result.operations == 0 {
            return "All enabled sync pairs are already current."
        }
        var parts = [
            "Folder sync finished",
            "\(result.copied) copied",
            "\(result.deleted) deleted"
        ]
        if result.skipped > 0 {
            parts.append("\(result.skipped) skipped")
        }
        if result.failed > 0 {
            parts.append("\(result.failed) failed")
        }
        return parts.joined(separator: ", ") + "."
    }
}
