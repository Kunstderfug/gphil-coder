import Foundation
import GPhilCoderCore

struct MediaCopyRunConfiguration {
    let sourceRoots: [URL]
    let destinationRoot: URL?
    let destinationLayout: MediaCopyDestinationLayout
    let filter: MediaFileFilter
    let selectedExtensions: Set<String>?
    let fileNameFilter: MediaFileNameFilter
    let previewLimit: Int
}

struct MediaPreviewConfiguration {
    let sourceRoots: [URL]
    let filter: MediaFileFilter
    let selectedExtensions: Set<String>?
    let fileNameFilter: MediaFileNameFilter
    let renameSettings: MediaRenameSettings
    let previewLimit: Int

    static let empty = MediaPreviewConfiguration(
        sourceRoots: [],
        filter: .all,
        selectedExtensions: nil,
        fileNameFilter: MediaFileNameFilter(),
        renameSettings: MediaRenameSettings(),
        previewLimit: 0
    )
}

@MainActor
final class MediaFileCoordinator: ObservableObject {
    @Published var fileManagementMode: FileManagementMode = .copy
    @Published var mediaCopySourceRoots: [URL] = []
    @Published var mediaCopyDestinationRoot: URL?
    @Published var mediaCopyDestinationLayout: MediaCopyDestinationLayout = .sourceFolders
    @Published var mediaCopyFilter: MediaFileFilter = .audio
    @Published var mediaCopyAudioExtensions: Set<String> = MediaFileFilter.audio.fileExtensions
    @Published var mediaCopyVideoExtensions: Set<String> = MediaFileFilter.video.fileExtensions
    @Published var mediaFileNameFilterQuery = ""
    @Published var mediaRenameOperation: MediaRenameOperation = .pattern
    @Published var mediaRenamePattern = "{name}"
    @Published var mediaRenameFindText = ""
    @Published var mediaRenameReplacementText = ""
    @Published var mediaRenameIsCaseSensitive = false
    @Published var mediaRenameAddedText = ""
    @Published var mediaRenameTextPlacement: MediaRenameTextPlacement = .suffix
    @Published var mediaRenameCaseStyle: MediaRenameCaseStyle = .titleCase
    @Published var mediaRenameSort: MediaRenameSort = .name
    @Published var mediaRenameStartIndex = 1
    @Published var mediaRenameIndexStep = 1
    @Published var mediaRenameIndexPadding = 2
    @Published var mediaCopyPlan: MediaCopyBatchPlan?
    @Published var mediaDeletePlan: MediaDeletePlan?
    @Published var mediaRenamePlan: MediaRenamePlan?
    @Published var isMediaRenamePreviewStale = false
    @Published var mediaCopyProgress: MediaCopyProgress?
    @Published var isMediaCopyScanning = false
    @Published var isMediaCopying = false
    @Published var isMediaCopyFinalizing = false
    @Published var isMediaDeleting = false
    @Published var isMediaRenaming = false
    @Published var mediaRenameProgressVerb = "renamed"
    @Published var mediaCopyQueue: [MediaCopyWorkflow] = []
    @Published var currentMediaCopyWorkflowID: UUID?
    @Published var mediaRenameUndoStack: [MediaRenameHistoryTransaction] = [] {
        didSet { persistRenameHistory() }
    }
    @Published var mediaRenameRedoStack: [MediaRenameHistoryTransaction] = [] {
        didSet { persistRenameHistory() }
    }

    let setStatusMessage: @MainActor (String) -> Void
    let validateFolders: @MainActor (_ sourceRoot: URL, _ destinationRoot: URL) -> Bool
    let promptConflictResolution: @MainActor ([MediaCopyBatchPlan]) -> MediaCopyConflictResolution?
    let promptTrash: @MainActor (
        _ itemCount: Int,
        _ totalSize: Int64,
        _ sourceRootCount: Int,
        _ filter: MediaFileFilter,
        _ selectedExtensions: Set<String>,
        _ fileNameFilter: MediaFileNameFilter
    ) -> Bool
    let promptRename: @MainActor (_ itemCount: Int, _ unchangedCount: Int) -> Bool
    let promptRenameHistory: @MainActor (
        _ transaction: MediaRenameHistoryTransaction,
        _ direction: MediaRenameHistoryDirection
    ) -> Bool
    let recordPendingTrashIntents: @MainActor ([TrashableFileItem]) throws -> [UUID: PendingTrashSourceRecord]
    let moveTrashItemAndRecord: @MainActor (
        _ item: TrashableFileItem,
        _ pendingRecord: PendingTrashSourceRecord
    ) throws -> TrashMoveRecordResult
    let removePendingTrashRecords: @MainActor (Set<UUID>) throws -> Void
    let removePendingTrashRecordIfOriginalStillExists: @MainActor (PendingTrashSourceRecord) -> Void
    let removeInputsAndResetJobs: @MainActor (_ movedPaths: Set<String>) -> Void
    let resetJobsForMediaMutation: @MainActor () -> Void
    let persistRenameHistory: @MainActor () -> Void
    let notifyCompletion: @MainActor (_ title: String, _ body: String) -> Void

    var mediaCopyTask: Task<Void, Never>?
    var mediaFileNameFilterRefreshTask: Task<Void, Never>?
    var mediaFileInventory: [MediaFileInventoryRecord] = []
    var mediaFileInventorySourceRootPaths: [String] = []

    init(
        setStatusMessage: @escaping @MainActor (String) -> Void,
        validateFolders: @escaping @MainActor (_ sourceRoot: URL, _ destinationRoot: URL) -> Bool,
        promptConflictResolution: @escaping @MainActor ([MediaCopyBatchPlan]) -> MediaCopyConflictResolution?,
        promptTrash: @escaping @MainActor (
            _ itemCount: Int,
            _ totalSize: Int64,
            _ sourceRootCount: Int,
            _ filter: MediaFileFilter,
            _ selectedExtensions: Set<String>,
            _ fileNameFilter: MediaFileNameFilter
        ) -> Bool,
        promptRename: @escaping @MainActor (_ itemCount: Int, _ unchangedCount: Int) -> Bool,
        promptRenameHistory: @escaping @MainActor (
            _ transaction: MediaRenameHistoryTransaction,
            _ direction: MediaRenameHistoryDirection
        ) -> Bool,
        recordPendingTrashIntents: @escaping @MainActor ([TrashableFileItem]) throws -> [UUID: PendingTrashSourceRecord],
        moveTrashItemAndRecord: @escaping @MainActor (
            _ item: TrashableFileItem,
            _ pendingRecord: PendingTrashSourceRecord
        ) throws -> TrashMoveRecordResult,
        removePendingTrashRecords: @escaping @MainActor (Set<UUID>) throws -> Void,
        removePendingTrashRecordIfOriginalStillExists: @escaping @MainActor (PendingTrashSourceRecord) -> Void,
        removeInputsAndResetJobs: @escaping @MainActor (_ movedPaths: Set<String>) -> Void,
        resetJobsForMediaMutation: @escaping @MainActor () -> Void,
        persistRenameHistory: @escaping @MainActor () -> Void,
        notifyCompletion: @escaping @MainActor (_ title: String, _ body: String) -> Void
    ) {
        self.setStatusMessage = setStatusMessage
        self.validateFolders = validateFolders
        self.promptConflictResolution = promptConflictResolution
        self.promptTrash = promptTrash
        self.promptRename = promptRename
        self.promptRenameHistory = promptRenameHistory
        self.recordPendingTrashIntents = recordPendingTrashIntents
        self.moveTrashItemAndRecord = moveTrashItemAndRecord
        self.removePendingTrashRecords = removePendingTrashRecords
        self.removePendingTrashRecordIfOriginalStillExists = removePendingTrashRecordIfOriginalStillExists
        self.removeInputsAndResetJobs = removeInputsAndResetJobs
        self.resetJobsForMediaMutation = resetJobsForMediaMutation
        self.persistRenameHistory = persistRenameHistory
        self.notifyCompletion = notifyCompletion
    }

    func scanCopyFiles() {
        runCopyPreflight(copyAfterScan: false, configuration: mediaCopyRunConfiguration)
    }

    func copyFilteredFiles() {
        runCopyPreflight(copyAfterScan: true, configuration: mediaCopyRunConfiguration)
    }

    func runQueuedWorkflows(_ workflows: [MediaCopyWorkflow]) {
        mediaCopyTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = true
        isMediaCopying = false
        isMediaCopyFinalizing = false
        setStatusMessage(
            "Scanning \(workflows.count) queued file copy workflow\(workflows.count == 1 ? "" : "s")..."
        )

        mediaCopyTask = Task { [weak self] in
            await self?.runQueuedWorkflowTask(workflows)
        }
    }

    func cancel() {
        guard !isMediaCopyFinalizing else { return }
        mediaCopyTask?.cancel()
        mediaCopyTask = nil
        cancelFileNameFilterRefresh()
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
    }

    func refreshDeletePreview(configuration: MediaPreviewConfiguration) {
        scanInventoryThenRefresh(.delete, configuration: configuration)
    }

    func refreshRenamePreview(configuration: MediaPreviewConfiguration) {
        scanInventoryThenRefresh(.rename, configuration: configuration)
    }

    func resetForCopyRun() {
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = nil
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
    }

    func refreshDeletePreviewIfNeeded(configuration: MediaPreviewConfiguration) {
        guard fileManagementMode == .delete else { return }

        guard !configuration.sourceRoots.isEmpty,
            hasSelectedExtensions(configuration)
        else {
            mediaDeletePlan = nil
            return
        }

        if inventoryMatches(configuration.sourceRoots) {
            rebuildDeletePreviewFromInventory(configuration: configuration)
        } else {
            scanInventoryThenRefresh(.delete, configuration: configuration)
        }
    }

    func refreshRenamePreviewIfNeeded(configuration: MediaPreviewConfiguration) {
        guard fileManagementMode == .rename else { return }

        guard !configuration.sourceRoots.isEmpty,
            hasSelectedExtensions(configuration)
        else {
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            return
        }

        if inventoryMatches(configuration.sourceRoots) {
            rebuildRenamePreviewFromInventory(configuration: configuration)
        } else {
            scanInventoryThenRefresh(.rename, configuration: configuration)
        }
    }

    func rebuildRenamePreviewFromInventory(configuration: MediaPreviewConfiguration) {
        guard inventoryMatches(configuration.sourceRoots) else {
            scanInventoryThenRefresh(.rename, configuration: configuration)
            return
        }

        let plan = MediaCopyPlanner.buildRenamePlan(
            sourceRoots: configuration.sourceRoots,
            filter: configuration.filter,
            selectedExtensions: configuration.selectedExtensions,
            fileNameFilter: configuration.fileNameFilter,
            itemLimit: configuration.previewLimit,
            settings: configuration.renameSettings,
            inventory: mediaFileInventory
        )
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = plan
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        setStatusMessage(Self.mediaRenameScanStatusMessage(for: plan))
    }

    private func runCopyPreflight(
        copyAfterScan: Bool,
        configuration: MediaCopyRunConfiguration
    ) {
        guard !configuration.sourceRoots.isEmpty,
            let destinationRoot = configuration.destinationRoot
        else {
            setStatusMessage("Choose source and destination folders before copying media files.")
            return
        }

        for sourceRoot in configuration.sourceRoots {
            let resolvedDestination = configuration.destinationLayout.resolvedDestinationRoot(
                for: sourceRoot,
                destinationRoot: destinationRoot
            )
            guard validateFolders(sourceRoot, resolvedDestination) else { return }
        }

        mediaCopyTask?.cancel()
        resetForCopyRun()
        isMediaCopyScanning = true
        isMediaCopying = false

        let filter = configuration.filter
        let selectedExtensions = configuration.selectedExtensions
        let fileNameFilter = configuration.fileNameFilter
        let candidateLimit = copyAfterScan ? nil : configuration.previewLimit
        setStatusMessage(
            "Scanning \(configuration.sourceRoots.count) source folder\(configuration.sourceRoots.count == 1 ? "" : "s")..."
        )

        mediaCopyTask = Task { [weak self] in
            await self?.runCopyTask(
                configuration: MediaCopyBatchConfiguration(
                    sourceRoots: configuration.sourceRoots,
                    destinationRoot: destinationRoot,
                    destinationLayout: configuration.destinationLayout,
                    filter: filter,
                    selectedExtensions: selectedExtensions,
                    fileNameFilter: fileNameFilter
                ),
                candidateLimit: candidateLimit,
                copyAfterScan: copyAfterScan
            )
        }
    }

    private func scanInventoryThenRefresh(
        _ targetMode: FileManagementMode,
        configuration: MediaPreviewConfiguration
    ) {
        guard targetMode == .delete || targetMode == .rename else { return }
        guard !configuration.sourceRoots.isEmpty else { return }

        guard hasSelectedExtensions(configuration) else {
            if targetMode == .delete {
                mediaDeletePlan = nil
            } else {
                mediaRenamePlan = nil
                isMediaRenamePreviewStale = false
            }
            return
        }

        let sourceRoots = configuration.sourceRoots

        mediaCopyTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = true
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        setStatusMessage(
            "Scanning \(sourceRoots.count) source folder\(sourceRoots.count == 1 ? "" : "s") into memory..."
        )

        mediaCopyTask = Task { [weak self] in
            await self?.runInventoryTask(
                targetMode: targetMode,
                configuration: configuration
            )
        }
    }

    private func runInventoryTask(
        targetMode: FileManagementMode,
        configuration: MediaPreviewConfiguration
    ) async {
        do {
            let sourceRoots = configuration.sourceRoots
            let worker = Task.detached(priority: .userInitiated) {
                try MediaCopyPlanner.scanFileInventory(sourceRoots: sourceRoots)
            }
            let inventory = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled else { return }

            setInventory(
                inventory,
                sourceRoots.map { $0.standardizedFileURL.path }
            )
            isMediaCopyScanning = false
            mediaCopyTask = nil

            let latestConfiguration = mediaPreviewConfiguration
            guard fileManagementMode == targetMode else {
                refreshDeletePreviewIfNeeded(configuration: latestConfiguration)
                refreshRenamePreviewIfNeeded(configuration: latestConfiguration)
                return
            }

            switch targetMode {
            case .delete:
                rebuildDeletePreviewFromInventory(configuration: latestConfiguration)
            case .rename:
                rebuildRenamePreviewFromInventory(configuration: latestConfiguration)
            case .copy:
                break
            }
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            isMediaCopyScanning = false
            mediaCopyTask = nil
            setStatusMessage("File inventory scan cancelled.")
        } catch {
            guard !Task.isCancelled else { return }
            setInventory([], [])
            if targetMode == .delete {
                mediaDeletePlan = nil
            } else {
                mediaRenamePlan = nil
                isMediaRenamePreviewStale = false
            }
            mediaCopyProgress = nil
            isMediaCopyScanning = false
            mediaCopyTask = nil
            setStatusMessage("Could not scan source folders: \(error.localizedDescription)")
        }
    }

    private func rebuildDeletePreviewFromInventory(configuration: MediaPreviewConfiguration) {
        guard inventoryMatches(configuration.sourceRoots) else {
            scanInventoryThenRefresh(.delete, configuration: configuration)
            return
        }

        let plan = MediaCopyPlanner.buildDeletePlan(
            sourceRoots: configuration.sourceRoots,
            filter: configuration.filter,
            selectedExtensions: configuration.selectedExtensions ?? [],
            fileNameFilter: configuration.fileNameFilter,
            candidateLimit: configuration.previewLimit,
            inventory: mediaFileInventory
        )
        mediaCopyPlan = nil
        mediaDeletePlan = plan
        mediaRenamePlan = nil
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        setStatusMessage(Self.mediaDeleteScanStatusMessage(for: plan))
    }

    private func inventoryMatches(_ sourceRoots: [URL]) -> Bool {
        !sourceRoots.isEmpty
            && mediaFileInventorySourceRootPaths == sourceRoots.map { $0.standardizedFileURL.path }
    }

    private func hasSelectedExtensions(_ configuration: MediaPreviewConfiguration) -> Bool {
        !configuration.filter.supportsExtensionSelection
            || configuration.selectedExtensions?.isEmpty == false
    }

    private func runCopyTask(
        configuration: MediaCopyBatchConfiguration,
        candidateLimit: Int?,
        copyAfterScan: Bool
    ) async {
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try MediaCopyBatchPlanner.buildPlan(
                    configuration: configuration,
                    candidateLimit: candidateLimit
                )
            }
            let plan = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled else { return }

            mediaCopyPlan = plan
            isMediaCopyScanning = false

            guard copyAfterScan else {
                setStatusMessage(Self.mediaCopyScanStatusMessage(for: plan))
                mediaCopyTask = nil
                return
            }

            guard plan.hasCopyableContent else {
                let completionMessage =
                    "No \(configuration.filter.fileTypeName) files found in the selected source folders."
                setStatusMessage(completionMessage)
                notifyCompletion("File copy finished", completionMessage)
                mediaCopyTask = nil
                return
            }

            guard plan.canExecute else {
                setStatusMessage(
                    "Copy plan blocked by \(plan.structuralConflictCount) incompatible file, package, or folder destination\(plan.structuralConflictCount == 1 ? "" : "s"). Change the layout or source selection."
                )
                mediaCopyTask = nil
                return
            }

            guard let resolution = promptConflictResolution([plan]) else {
                setStatusMessage("Media copy cancelled.")
                mediaCopyTask = nil
                return
            }

            isMediaCopying = true
            let progressStartedAt = Date()
            setProgress(
                MediaCopyProgress(
                    completed: 0,
                    total: plan.candidates.count,
                    copied: 0,
                    skippedExisting: 0,
                    failed: 0,
                    copiedBytes: 0,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: progressStartedAt,
                    updatedAt: progressStartedAt,
                    currentName: nil
                )
            )
            setStatusMessage(
                "Copying \(plan.candidateCount) \(configuration.filter.fileTypeName) file\(plan.candidateCount == 1 ? "" : "s")..."
            )

            let result = await copyMediaCopyBatchPlan(plan, conflictResolution: resolution)

            if Task.isCancelled {
                isMediaCopying = false
                mediaCopyTask = nil
                setStatusMessage(
                    Self.mediaCopyResultStatusMessage(
                        result,
                        filter: configuration.filter,
                        destinationRoot: configuration.destinationRoot
                    )
                )
                return
            }

            isMediaCopying = false
            mediaCopyTask = nil
            let completionMessage = Self.mediaCopyResultStatusMessage(
                result,
                filter: configuration.filter,
                destinationRoot: configuration.destinationRoot
            )
            setStatusMessage(completionMessage)
            notifyCompletion("File copy finished", completionMessage)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            isMediaCopyScanning = false
            isMediaCopying = false
            mediaCopyTask = nil
            setStatusMessage("Media copy cancelled.")
        } catch {
            guard !Task.isCancelled else { return }
            mediaCopyPlan = nil
            mediaCopyProgress = nil
            isMediaCopyScanning = false
            isMediaCopying = false
            mediaCopyTask = nil
            setStatusMessage("Could not prepare media copy: \(error.localizedDescription)")
        }
    }

    private func runQueuedWorkflowTask(_ workflows: [MediaCopyWorkflow]) async {
        do {
            var workflowPlans: [(workflow: MediaCopyWorkflow, plan: MediaCopyBatchPlan)] = []

            for (index, workflow) in workflows.enumerated() {
                guard !Task.isCancelled else { return }
                currentMediaCopyWorkflowID = workflow.id
                setStatusMessage(
                    "Scanning queued workflow \(index + 1) of \(workflows.count)..."
                )

                let worker = Task.detached(priority: .userInitiated) {
                    try MediaCopyBatchPlanner.buildPlan(
                        configuration: workflow.configuration
                    )
                }
                let plan = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                workflowPlans.append((workflow, plan))
            }

            guard !Task.isCancelled else { return }

            isMediaCopyScanning = false

            let nonEmptyWorkflowPlans = workflowPlans.filter(\.plan.hasCopyableContent)
            guard !nonEmptyWorkflowPlans.isEmpty else {
                let completionMessage = "No files found in the queued file copy workflows."
                currentMediaCopyWorkflowID = nil
                mediaCopyTask = nil
                setStatusMessage(completionMessage)
                notifyCompletion("File copy queue finished", completionMessage)
                return
            }

            let nonEmptyPlans = nonEmptyWorkflowPlans.map(\.plan)
            let queueReviewPlans = MediaCopyBatchPlanner.buildQueueReviewPlans(
                from: nonEmptyPlans
            )
            guard queueReviewPlans.allSatisfy(\.canExecute) else {
                currentMediaCopyWorkflowID = nil
                mediaCopyTask = nil
                setStatusMessage(
                    "File copy queue blocked by incompatible file, package, or folder destinations. Change the affected workflow layout or sources."
                )
                return
            }

            guard let resolution = promptConflictResolution(queueReviewPlans) else {
                currentMediaCopyWorkflowID = nil
                mediaCopyTask = nil
                setStatusMessage("File copy queue cancelled.")
                return
            }

            isMediaCopying = true
            setStatusMessage(
                "Copying \(nonEmptyWorkflowPlans.count) queued workflow\(nonEmptyWorkflowPlans.count == 1 ? "" : "s")..."
            )

            var aggregateResult = MediaCopyResult(
                total: nonEmptyPlans.reduce(0) { $0 + $1.candidates.count }
            )
            var ownedDestinationEvidence: [String: MediaCopyPathEvidence] = [:]
            var retainedTransactions: [MediaCopyTransactionExecutor.RetainedTransaction] = []

            for workflowPlan in nonEmptyWorkflowPlans {
                guard !Task.isCancelled else {
                    aggregateResult.cancelled = true
                    break
                }

                currentMediaCopyWorkflowID = workflowPlan.workflow.id
                let executionPlan = workflowPlan.plan.rebasingDestinationEvidence(
                    forOwnedChanges: ownedDestinationEvidence
                )
                mediaCopyPlan = executionPlan
                let execution = await copyMediaCopyBatchPlanRetainingRollback(
                    executionPlan,
                    conflictResolution: resolution
                )
                let result = execution.result

                aggregateResult.copied += result.copied
                aggregateResult.skippedExisting += result.skippedExisting
                aggregateResult.failed += result.failed
                aggregateResult.failedNames.append(contentsOf: result.failedNames)
                aggregateResult.createdDirectories += result.createdDirectories
                aggregateResult.failedDirectories += result.failedDirectories
                aggregateResult.failedDirectoryNames.append(
                    contentsOf: result.failedDirectoryNames
                )
                aggregateResult.cancelled = aggregateResult.cancelled || result.cancelled
                aggregateResult.rejected = aggregateResult.rejected || result.rejected
                aggregateResult.stalePlan = aggregateResult.stalePlan || result.stalePlan
                aggregateResult.rollbackFailed =
                    aggregateResult.rollbackFailed || result.rollbackFailed
                aggregateResult.recoveryPath = result.recoveryPath ?? aggregateResult.recoveryPath
                ownedDestinationEvidence.merge(
                    result.appliedDestinationEvidence,
                    uniquingKeysWith: { _, latest in latest }
                )
                if let transaction = execution.transaction {
                    retainedTransactions.append(transaction)
                }
                if result.cancelled || result.rejected || result.rollbackFailed { break }
            }

            aggregateResult.cancelled = aggregateResult.cancelled || Task.isCancelled
            let queueDidNotComplete = aggregateResult.cancelled
                || aggregateResult.rejected
                || aggregateResult.rollbackFailed
            var queueReachedCommitPoint = false
            if queueDidNotComplete {
                var rollbackComplete = !aggregateResult.rollbackFailed
                for transaction in retainedTransactions.reversed() {
                    if !(await MediaCopyTransactionExecutor.rollbackRetainedTransaction(
                        transaction
                    )) {
                        rollbackComplete = false
                        aggregateResult.recoveryPath = transaction.recoveryPath
                    }
                }
                if rollbackComplete {
                    aggregateResult.copied = 0
                    aggregateResult.createdDirectories = 0
                    aggregateResult.appliedDestinationEvidence = [:]
                } else {
                    aggregateResult.rollbackFailed = true
                }
            } else {
                isMediaCopying = false
                isMediaCopyFinalizing = true
                currentMediaCopyWorkflowID = nil
                queueReachedCommitPoint = true
                for transaction in retainedTransactions {
                    if !(await MediaCopyTransactionExecutor.finalizeRetainedTransaction(
                        transaction
                    )) {
                        aggregateResult.rollbackFailed = true
                        aggregateResult.recoveryPath = transaction.recoveryPath
                    }
                }
            }

            if Task.isCancelled && !queueReachedCommitPoint {
                isMediaCopying = false
                isMediaCopyFinalizing = false
                currentMediaCopyWorkflowID = nil
                mediaCopyTask = nil
                setStatusMessage(
                    Self.mediaCopyQueueResultStatusMessage(
                        aggregateResult,
                        workflowCount: nonEmptyWorkflowPlans.count
                    )
                )
                return
            }

            isMediaCopying = false
            isMediaCopyFinalizing = false
            currentMediaCopyWorkflowID = nil
            mediaCopyTask = nil
            let completionMessage = Self.mediaCopyQueueResultStatusMessage(
                aggregateResult,
                workflowCount: nonEmptyWorkflowPlans.count
            )
            setStatusMessage(completionMessage)
            notifyCompletion("File copy queue finished", completionMessage)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            isMediaCopyScanning = false
            isMediaCopying = false
            isMediaCopyFinalizing = false
            currentMediaCopyWorkflowID = nil
            mediaCopyTask = nil
            setStatusMessage("File copy queue cancelled.")
        } catch {
            guard !Task.isCancelled else { return }
            mediaCopyProgress = nil
            isMediaCopyScanning = false
            isMediaCopying = false
            isMediaCopyFinalizing = false
            currentMediaCopyWorkflowID = nil
            mediaCopyTask = nil
            setStatusMessage("Could not run file copy queue: \(error.localizedDescription)")
        }
    }

    private func copyMediaCopyBatchPlan(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution
    ) async -> MediaCopyResult {
        await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: conflictResolution,
            publishProgress: { [weak self] progress in
                guard let self else { return }
                mediaCopyProgress = progress
                let speedDetail = progress.bytesPerSecond
                    .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
                setStatusMessage(
                    "Copied \(progress.copied), skipped \(progress.skippedExisting), failed \(progress.failed) of \(progress.total)\(speedDetail)."
                )
            }
        )
    }

    private func copyMediaCopyBatchPlanRetainingRollback(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution
    ) async -> MediaCopyTransactionExecutor.RetainedExecution {
        await MediaCopyTransactionExecutor.executeRetainingRollback(
            plan,
            conflictResolution: conflictResolution,
            publishProgress: { [weak self] progress in
                guard let self else { return }
                mediaCopyProgress = progress
                let speedDetail = progress.bytesPerSecond
                    .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
                setStatusMessage(
                    "Copied \(progress.copied), skipped \(progress.skippedExisting), failed \(progress.failed) of \(progress.total)\(speedDetail)."
                )
            }
        )
    }

    private static func mediaCopyScanStatusMessage(for plan: MediaCopyBatchPlan) -> String {
        guard plan.hasCopyableContent else {
            return "No \(plan.filter.fileTypeName) files found in the selected source folders."
        }

        var details = [
            "Found \(plan.candidateCount) \(plan.filter.fileTypeName) file\(plan.candidateCount == 1 ? "" : "s")",
            "totaling \(plan.totalSizeBytes.formattedFileSize)"
        ]
        if plan.directoryCount > 0 {
            details.append(
                "\(plan.directoryCount) folder\(plan.directoryCount == 1 ? "" : "s")"
            )
        }
        if plan.conflictCount > 0 {
            details.append(
                "\(plan.conflictCount) destination conflict\(plan.conflictCount == 1 ? "" : "s")"
            )
        }
        if plan.structuralConflictCount > 0 {
            details.append(
                "\(plan.structuralConflictCount) incompatible destination\(plan.structuralConflictCount == 1 ? "" : "s") block execution"
            )
        }
        return details.joined(separator: ", ") + "."
    }

    private static func mediaCopyResultStatusMessage(
        _ result: MediaCopyResult,
        filter: MediaFileFilter,
        destinationRoot: URL
    ) -> String {
        if result.rollbackFailed {
            return "File copy could not restore every destination item. Recovery data was retained at \(result.recoveryPath ?? "the Copy transaction folder")."
        }
        if result.stalePlan {
            return "The source or destination changed after review. Scan and review the copy again; the destination is unchanged."
        }
        if result.rejected {
            return "File copy was rejected before the reviewed batch could be applied. The destination is unchanged."
        }
        if result.cancelled {
            return "Media copy cancelled. Transaction changes were rolled back."
        }

        var details = [
            "Copied \(result.copied) \(filter.fileTypeName) file\(result.copied == 1 ? "" : "s") to \(destinationRoot.lastPathComponent)."
        ]
        if result.createdDirectories > 0 {
            details.append(
                "Created \(result.createdDirectories) folder\(result.createdDirectories == 1 ? "" : "s")."
            )
        }
        if result.skippedExisting > 0 {
            details.append("Skipped \(result.skippedExisting) existing file\(result.skippedExisting == 1 ? "" : "s").")
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        if result.failedDirectories > 0 {
            details.append(
                "Failed \(result.failedDirectories) folder\(result.failedDirectories == 1 ? "" : "s"): \(result.failedDirectoryNames.prefix(3).joined(separator: ", "))\(result.failedDirectoryNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    private static func mediaDeleteScanStatusMessage(for plan: MediaDeletePlan) -> String {
        let scopeDescription = mediaDeleteScopeDescription(
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter
        )
        guard plan.hasDeletableContent else {
            return "No files matching \(scopeDescription) were found in the selected source folders."
        }

        return
            "Found \(plan.candidateCount) file\(plan.candidateCount == 1 ? "" : "s") matching \(scopeDescription), totaling \(plan.totalSizeBytes.formattedFileSize)."
    }

    static func mediaDeleteScopeDescription(
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter
    ) -> String {
        let typeDescription =
            filter.supportsExtensionSelection
            ? filter.readableExtensionList(selectedExtensions: selectedExtensions)
            : "all files"
        let nameQuery = fileNameFilter.trimmedQuery
        guard !nameQuery.isEmpty else { return typeDescription }
        return "\(typeDescription) with names containing \"\(nameQuery)\""
    }

    private static func mediaRenameScanStatusMessage(for plan: MediaRenamePlan) -> String {
        guard plan.hasRenameContent else {
            if let selectedExtensions = plan.selectedExtensions {
                return "No \(plan.filter.fileTypeName) files matching \(plan.filter.readableExtensionList(selectedExtensions: selectedExtensions)) were found in the selected source folders."
            }
            return "No matching files were found in the selected source folders."
        }

        var details = [
            "Found \(plan.itemCount) file\(plan.itemCount == 1 ? "" : "s") for rename preview",
            "\(plan.readyCount) ready"
        ]
        if plan.unchangedCount > 0 {
            details.append("\(plan.unchangedCount) unchanged")
        }
        if plan.blockedCount > 0 {
            details.append("\(plan.blockedCount) blocked")
        }
        details.append("totaling \(plan.totalSizeBytes.formattedFileSize)")
        return details.joined(separator: ", ") + "."
    }

    private static func mediaCopyQueueResultStatusMessage(
        _ result: MediaCopyResult,
        workflowCount: Int
    ) -> String {
        if result.rollbackFailed {
            return "File copy queue stopped with incomplete recovery. Recovery data was retained at \(result.recoveryPath ?? "a Copy transaction folder")."
        }
        if result.stalePlan {
            return "File copy queue stopped because a source or destination changed after review. Completed queue changes were rolled back, and the stale workflow made no destination changes. Scan and review the workflow again."
        }
        if result.rejected {
            return "File copy queue stopped because a reviewed workflow could not be applied completely."
        }
        if result.cancelled {
            return "File copy queue cancelled. Active workflow changes were rolled back."
        }

        var details = [
            "Finished \(workflowCount) file copy workflow\(workflowCount == 1 ? "" : "s"): \(result.copied) copied."
        ]
        if result.createdDirectories > 0 {
            details.append(
                "\(result.createdDirectories) folder\(result.createdDirectories == 1 ? "" : "s") created."
            )
        }
        if result.skippedExisting > 0 {
            details.append("\(result.skippedExisting) existing file\(result.skippedExisting == 1 ? "" : "s") skipped.")
        }
        if result.failed > 0 {
            details.append(
                "\(result.failed) failed: \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        if result.failedDirectories > 0 {
            details.append(
                "\(result.failedDirectories) folder failure\(result.failedDirectories == 1 ? "" : "s")."
            )
        }
        return details.joined(separator: " ")
    }
}
