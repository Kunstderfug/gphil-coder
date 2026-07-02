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
        deleteDestinationItems: true,
        overwriteExisting: true,
        includedFileExtensions: nil,
        autoSyncEnabled: false,
        watchOrigins: [],
        previewLimit: 0
    )
}

@MainActor
final class FolderSyncCoordinator {
    private static let autoDebounceNanoseconds: UInt64 = 1_250_000_000

    private let getIsBusy: @MainActor () -> Bool
    private let setPlan: @MainActor (FolderSyncPlan?) -> Void
    private let setScannedCounts: @MainActor (_ operations: Int, _ copies: Int, _ deletes: Int, _ size: Int64) -> Void
    private let setProgress: @MainActor (FolderSyncProgress?) -> Void
    private let setCurrentPair: @MainActor (UUID?) -> Void
    private let setScanning: @MainActor (Bool) -> Void
    private let setSyncing: @MainActor (Bool) -> Void
    private let setWatching: @MainActor (Bool) -> Void
    private let setStatusMessage: @MainActor (String) -> Void
    private let markPair: @MainActor (_ id: UUID, _ state: SyncPairState, _ message: String, _ lastSyncedAt: Date?) -> Void
    private let collisionMessage: @MainActor ([SyncFolderPair]) -> String?
    private let prepareFileAccess: @MainActor (_ pairs: [SyncFolderPair], _ triggeredAutomatically: Bool) -> [SyncFolderPair]?
    private let validateFolders: @MainActor (_ origin: URL, _ destination: URL, _ showsAlert: Bool) -> Bool
    private let releaseScopes: @MainActor () -> Void
    private let notifyCompletion: @MainActor (_ title: String, _ body: String) -> Void
    private let makeConfiguration: @MainActor () -> FolderSyncRunConfiguration

    private var folderSyncTask: Task<Void, Never>?
    private var folderSyncAutoTask: Task<Void, Never>?
    private var folderSyncWatcher: FolderSyncWatcher?
    private var folderSyncPendingAfterCurrentRun = false

    init(
        getIsBusy: @escaping @MainActor () -> Bool,
        setPlan: @escaping @MainActor (FolderSyncPlan?) -> Void,
        setScannedCounts: @escaping @MainActor (_ operations: Int, _ copies: Int, _ deletes: Int, _ size: Int64) -> Void,
        setProgress: @escaping @MainActor (FolderSyncProgress?) -> Void,
        setCurrentPair: @escaping @MainActor (UUID?) -> Void,
        setScanning: @escaping @MainActor (Bool) -> Void,
        setSyncing: @escaping @MainActor (Bool) -> Void,
        setWatching: @escaping @MainActor (Bool) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        markPair: @escaping @MainActor (_ id: UUID, _ state: SyncPairState, _ message: String, _ lastSyncedAt: Date?) -> Void,
        collisionMessage: @escaping @MainActor ([SyncFolderPair]) -> String?,
        prepareFileAccess: @escaping @MainActor (_ pairs: [SyncFolderPair], _ triggeredAutomatically: Bool) -> [SyncFolderPair]?,
        validateFolders: @escaping @MainActor (_ origin: URL, _ destination: URL, _ showsAlert: Bool) -> Bool,
        releaseScopes: @escaping @MainActor () -> Void,
        notifyCompletion: @escaping @MainActor (_ title: String, _ body: String) -> Void,
        makeConfiguration: @escaping @MainActor () -> FolderSyncRunConfiguration
    ) {
        self.getIsBusy = getIsBusy
        self.setPlan = setPlan
        self.setScannedCounts = setScannedCounts
        self.setProgress = setProgress
        self.setCurrentPair = setCurrentPair
        self.setScanning = setScanning
        self.setSyncing = setSyncing
        self.setWatching = setWatching
        self.setStatusMessage = setStatusMessage
        self.markPair = markPair
        self.collisionMessage = collisionMessage
        self.prepareFileAccess = prepareFileAccess
        self.validateFolders = validateFolders
        self.releaseScopes = releaseScopes
        self.notifyCompletion = notifyCompletion
        self.makeConfiguration = makeConfiguration
    }

    func scan(configuration: FolderSyncRunConfiguration) {
        run(syncAfterScan: false, triggeredAutomatically: false, configuration: configuration)
    }

    func syncNow(configuration: FolderSyncRunConfiguration) {
        run(syncAfterScan: true, triggeredAutomatically: false, configuration: configuration)
    }

    func cancel() {
        guard getIsBusy() else { return }
        folderSyncTask?.cancel()
        folderSyncAutoTask?.cancel()
        folderSyncTask = nil
        folderSyncAutoTask = nil
        folderSyncPendingAfterCurrentRun = false
        releaseScopes()
        setScanning(false)
        setSyncing(false)
        setCurrentPair(nil)
        setProgress(nil)
        setStatusMessage("Folder sync cancelled.")
    }

    func configureWatcher(configuration: FolderSyncRunConfiguration) {
        folderSyncWatcher?.stop()
        folderSyncWatcher = nil
        setWatching(false)
        guard configuration.autoSyncEnabled else { return }
        guard !configuration.watchOrigins.isEmpty else { return }

        let watcher = FolderSyncWatcher(urls: configuration.watchOrigins) { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleAutomaticFolderSync()
            }
        }
        guard watcher.isWatching else { return }

        folderSyncWatcher = watcher
        setWatching(true)
    }

    private func run(
        syncAfterScan: Bool,
        triggeredAutomatically: Bool,
        configuration: FolderSyncRunConfiguration
    ) {
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
            let destinationLayout = configuration.destinationLayout
            let deleteDestinationItems = configuration.deleteDestinationItems
            let overwriteExisting = configuration.overwriteExisting
            let includedFileExtensions = configuration.includedFileExtensions
            let previewLimit = configuration.previewLimit

            var fullPlans: [(pair: SyncFolderPair, plan: FolderSyncPlan)] = []
            var previewPlan: FolderSyncPlan?
            var operationCount = 0
            var copyCount = 0
            var deleteCount = 0
            var totalSize: Int64 = 0

            for pair in pairs {
                guard !Task.isCancelled else { return }
                setCurrentPair(pair.id)
                markPair(pair.id, .syncing, "Scanning...", nil)
                let effectiveDestinationRoot = pair.effectiveDestinationURL(
                    layout: destinationLayout,
                    allPairs: pairs
                )

                let fullWorker = Task.detached(priority: .userInitiated) {
                    try FolderSyncPlanner.buildPlan(
                        originRoot: pair.originURL,
                        destinationRoot: effectiveDestinationRoot,
                        syncDeletes: deleteDestinationItems,
                        includedFileExtensions: includedFileExtensions
                    )
                }
                let fullPlan = try await withTaskCancellationHandler {
                    try await fullWorker.value
                } onCancel: {
                    fullWorker.cancel()
                }
                fullPlans.append((pair, fullPlan))
                operationCount += fullPlan.operationCount
                copyCount += fullPlan.copyCount
                deleteCount += fullPlan.deleteCount
                totalSize += fullPlan.totalCopyBytes

                if previewPlan == nil {
                    let previewWorker = Task.detached(priority: .userInitiated) {
                        try FolderSyncPlanner.buildPlan(
                            originRoot: pair.originURL,
                            destinationRoot: effectiveDestinationRoot,
                            syncDeletes: deleteDestinationItems,
                            includedFileExtensions: includedFileExtensions,
                            operationLimit: previewLimit
                        )
                    }
                    previewPlan = try await withTaskCancellationHandler {
                        try await previewWorker.value
                    } onCancel: {
                        previewWorker.cancel()
                    }
                }

                let message = fullPlan.hasWork
                    ? "\(fullPlan.operationCount) pending change\(fullPlan.operationCount == 1 ? "" : "s")."
                    : "Already in sync."
                markPair(pair.id, .watching, message, nil)
            }

            guard !Task.isCancelled else { return }

            setPlan(previewPlan)
            setScannedCounts(operationCount, copyCount, deleteCount, totalSize)
            setScanning(false)

            guard syncAfterScan else {
                setCurrentPair(nil)
                folderSyncTask = nil
                releaseScopes()
                setStatusMessage(
                    operationCount == 0
                        ? "All enabled sync pairs are already current."
                        : "Found \(operationCount) pending sync change\(operationCount == 1 ? "" : "s")."
                )
                return
            }

            guard operationCount > 0 else {
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
            setStatusMessage("Syncing \(operationCount) change\(operationCount == 1 ? "" : "s")...")
            let result = await applyFolderSyncPlans(
                fullPlans,
                totalOperations: operationCount,
                totalBytes: totalSize,
                overwriteExisting: overwriteExisting
            )

            guard !Task.isCancelled else { return }

            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            let completionMessage = Self.folderSyncResultStatusMessage(result)
            setStatusMessage(completionMessage)
            notifyCompletion("Folder sync finished", completionMessage)
            runPendingFolderSyncIfNeeded()
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Folder sync cancelled.")
        } catch {
            guard !Task.isCancelled else { return }
            setScanning(false)
            setSyncing(false)
            setCurrentPair(nil)
            folderSyncTask = nil
            releaseScopes()
            setStatusMessage("Could not run folder sync: \(error.localizedDescription)")
        }
    }

    private func applyFolderSyncPlans(
        _ plans: [(pair: SyncFolderPair, plan: FolderSyncPlan)],
        totalOperations: Int,
        totalBytes: Int64,
        overwriteExisting: Bool
    ) async -> FolderSyncRunResult {
        var result = FolderSyncRunResult(pairs: plans.count, operations: totalOperations)
        let startedAt = Date()
        var completed = 0
        var copiedBytes: Int64 = 0

        for pairPlan in plans {
            guard !Task.isCancelled else {
                result.cancelled = true
                return result
            }

            setCurrentPair(pairPlan.pair.id)
            markPair(pairPlan.pair.id, .syncing, "Applying sync changes...", nil)
            let failedBeforePair = result.failed

            for operation in pairPlan.plan.operations {
                guard !Task.isCancelled else {
                    result.cancelled = true
                    return result
                }

                let progress = FolderSyncProgress(
                    completed: completed,
                    total: totalOperations,
                    copied: result.copied,
                    deleted: result.deleted,
                    skipped: result.skipped,
                    failed: result.failed,
                    copiedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    startedAt: startedAt,
                    updatedAt: Date(),
                    currentPath: operation.relativePath
                )
                setProgress(progress)

                let itemResult = await Task.detached(priority: .userInitiated) {
                    FolderSyncPlanner.applyOperation(
                        operation,
                        overwriteExisting: overwriteExisting
                    )
                }.value

                switch itemResult {
                case .applied:
                    switch operation.kind {
                    case .copyNew, .copyUpdated:
                        result.copied += 1
                        copiedBytes += operation.fileSizeBytes
                    case .deleteFile, .deleteDirectory:
                        result.deleted += 1
                    case .createDirectory:
                        break
                    }
                case .skippedExisting:
                    result.skipped += 1
                case .failed(let path):
                    result.failed += 1
                    result.failedPaths.append(path)
                }

                completed += 1
                let updatedProgress = FolderSyncProgress(
                    completed: completed,
                    total: totalOperations,
                    copied: result.copied,
                    deleted: result.deleted,
                    skipped: result.skipped,
                    failed: result.failed,
                    copiedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    startedAt: startedAt,
                    updatedAt: Date(),
                    currentPath: operation.relativePath
                )
                setProgress(updatedProgress)
                let speedDetail = updatedProgress.bytesPerSecond
                    .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
                setStatusMessage(
                    "Synced \(completed) of \(totalOperations). Copied \(result.copied), deleted \(result.deleted), failed \(result.failed)\(speedDetail)."
                )
            }

            let pairMessage = pairPlan.plan.operationCount == 0
                ? "Already in sync."
                : "Synced \(pairPlan.plan.operationCount) change\(pairPlan.plan.operationCount == 1 ? "" : "s")."
            markPair(
                pairPlan.pair.id,
                result.failed == failedBeforePair ? .succeeded : .failed,
                pairMessage,
                Date()
            )
        }

        return result
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

    private func runPendingFolderSyncIfNeeded() {
        guard folderSyncPendingAfterCurrentRun else { return }
        folderSyncPendingAfterCurrentRun = false
        scheduleAutomaticFolderSync()
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
