import Foundation
import GPhilCoderCore

@MainActor
extension EncoderViewModel {
    var isFolderSyncBusy: Bool {
        isSyncScanning || isSyncing || isSyncRecovering
    }

    var canAddSyncFolderPair: Bool {
        syncDraftOriginRoot != nil && syncDraftDestinationRoot != nil && !isFolderSyncBusy
    }

    var canSaveSyncFolderPairs: Bool {
        !syncFolderPairs.isEmpty && !isFolderSyncBusy
    }

    var canLoadSyncFolderPairs: Bool {
        !isFolderSyncBusy
    }

    var isEditingSyncFolderPair: Bool {
        editingSyncPairID != nil
    }

    var syncFolderPairSubmitTitle: String {
        isEditingSyncFolderPair ? "Save pair" : "Add pair"
    }

    var canRunFolderSync: Bool {
        folderSyncRecoveryAvailable
            && syncFolderPairs.contains { $0.isEnabled }
            && syncHasSelectedFileTypes
            && !isFolderSyncBusy
    }

    var canApplyReviewedFolderSyncPlan: Bool {
        canRunFolderSync && (syncPlan?.isApplyable ?? false)
    }

    var folderSyncRecoveryAvailable: Bool {
        folderSyncServices != nil
            && folderSyncServices?.historyStore.lastLoadFailure == nil
    }

    func canRollbackFolderSyncRun(_ run: FolderSyncHistoryRun) -> Bool {
        canRollbackFolderSyncRunID(run.id)
    }

    func canRollbackFolderSyncRunID(_ runID: UUID) -> Bool {
        !isFolderSyncBusy && syncRecoveryRecords.contains { $0.runID == runID }
    }

    var activeFolderSyncRecoveryRunIDs: [UUID] {
        var seen: Set<UUID> = []
        return syncRecoveryRecords.compactMap { record in
            seen.insert(record.runID).inserted ? record.runID : nil
        }
    }

    func canRetryFolderSyncRun(_ run: FolderSyncHistoryRun) -> Bool {
        !isFolderSyncBusy && !run.retryCandidates.isEmpty
    }

    var syncPairCount: Int {
        syncFolderPairs.count
    }

    var syncEnabledPairCount: Int {
        syncFolderPairs.filter(\.isEnabled).count
    }

    var syncPendingOperationCount: Int {
        syncScannedOperationCount
    }

    var syncPendingApplyOperationCount: Int {
        syncDispositionCount(.apply)
    }

    var syncPendingCopyCount: Int {
        guard let syncPlan else { return 0 }
        let dispositions = syncPlan.operationDispositions(
            overwriteExisting: syncOverwriteExisting
        )
        return syncPlan.operations.count { batchOperation in
            let kind = batchOperation.operation.kind
            return (kind == .copyNew || kind == .copyUpdated)
                && dispositions[batchOperation.key] == .apply
        }
    }

    var syncPendingDeleteCount: Int {
        syncScannedDeleteCount
    }

    var syncPendingSkipCount: Int {
        syncDispositionCount(.skipExisting)
    }

    var syncPendingConflictCount: Int {
        syncDispositionCount(.conflict)
    }

    var syncPendingTotalSize: Int64 {
        guard let syncPlan else { return 0 }
        let dispositions = syncPlan.operationDispositions(
            overwriteExisting: syncOverwriteExisting
        )
        return syncPlan.operations.reduce(0) { total, batchOperation in
            guard dispositions[batchOperation.key] == .apply else { return total }
            switch batchOperation.operation.kind {
            case .copyNew, .copyUpdated:
                return total + batchOperation.operation.fileSizeBytes
            case .createDirectory, .deleteFile, .deleteDirectory:
                return total
            }
        }
    }

    var syncBatchPreview: FolderSyncBatchPreview? {
        syncPlan?.preview(limit: Self.syncPreviewLimit)
    }

    var syncPreviewItems: [FolderSyncBatchOperation] {
        syncBatchPreview?.groups.flatMap(\.operations) ?? []
    }

    func syncDisposition(
        for operation: FolderSyncBatchOperation
    ) -> FolderSyncBatchOperationDisposition {
        syncPlan?.disposition(
            for: operation,
            overwriteExisting: syncOverwriteExisting
        ) ?? .apply
    }

    private func syncDispositionCount(
        _ disposition: FolderSyncBatchOperationDisposition
    ) -> Int {
        guard let syncPlan else { return 0 }
        return syncPlan.operationDispositions(overwriteExisting: syncOverwriteExisting)
            .values
            .count { $0 == disposition }
    }

    var syncDestinationLayoutOptions: [SyncDestinationLayout] {
        SyncDestinationLayout.allCases
    }

    var syncFileFilterOptions: [SyncFileFilter] {
        SyncFileFilter.allCases
    }

    var syncDestinationLayoutDetail: String {
        syncDestinationLayout.detail
    }

    var syncFileFilterDetail: String {
        syncFileFilter.detail
    }

    var syncFileFilterSummary: String {
        switch syncFileFilter {
        case .all:
            return "All files and folders"
        case .audio:
            return MediaFileFilter.audio.readableExtensionList()
        case .video:
            return MediaFileFilter.video.readableExtensionList()
        case .custom:
            let extensions = syncSelectedFileExtensions ?? []
            guard !extensions.isEmpty else { return "No extensions selected" }
            return extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
        }
    }

    var syncHasSelectedFileTypes: Bool {
        syncFileFilter != .custom || !(syncSelectedFileExtensions ?? []).isEmpty
    }

    var syncDraftOriginTitle: String {
        syncDraftOriginRoot?.path(percentEncoded: false) ?? "No origin folder selected"
    }

    var syncDraftDestinationTitle: String {
        syncDraftDestinationRoot?.path(percentEncoded: false) ?? "No destination folder selected"
    }

    var syncWatcherStatusTitle: String {
        guard syncAutoSyncEnabled else { return "Auto-sync paused" }
        guard syncEnabledPairCount > 0 else { return "No watched pairs" }
        return "Watching \(syncEnabledPairCount) pair\(syncEnabledPairCount == 1 ? "" : "s")"
    }

    func effectiveSyncDestinationPath(for pair: SyncFolderPair) -> String {
        effectiveSyncDestinationRoot(for: pair)
            .path(percentEncoded: false)
    }
}
