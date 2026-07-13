import Foundation
import GPhilCoderCore

struct FolderSyncExecutionUpdate: Sendable {
    let operation: FolderSyncBatchOperation
    let completed: Int
    let copiedBytes: Int64
    let result: FolderSyncRunResult
    let startedAt: Date
}

struct FolderSyncExecutionOutcome: Sendable {
    let result: FolderSyncRunResult
    let historyRun: FolderSyncHistoryRun
}

/// Owns the durable result record for one immutable reviewed Sync batch.
/// Filesystem mutations remain serialized by RecoverableFolderSyncMutationService.
@MainActor
final class FolderSyncRunExecutor {
    private let historyStore: FolderSyncHistoryStore
    private let mutationService: RecoverableFolderSyncMutationService

    init(services: FolderSyncServices) {
        historyStore = services.historyStore
        mutationService = services.mutationService
    }

    init(
        historyStore: FolderSyncHistoryStore,
        mutationService: RecoverableFolderSyncMutationService
    ) {
        self.historyStore = historyStore
        self.mutationService = mutationService
    }

    var historyRuns: [FolderSyncHistoryRun] {
        historyStore.runs
    }

    func recoveryRecords(runID: UUID? = nil) async -> [FolderSyncRecoveryRecord] {
        await mutationService.recoveryRecords(runID: runID)
    }

    @discardableResult
    func recordNoChange(
        plan: FolderSyncBatchPlan,
        trigger: FolderSyncHistoryTrigger,
        configuration: FolderSyncRunConfiguration
    ) throws -> FolderSyncHistoryRun {
        let now = Date()
        let run = makeRun(
            id: UUID(),
            plan: plan,
            trigger: trigger,
            configuration: configuration,
            startedAt: now,
            completedAt: now,
            items: []
        )
        try historyStore.record(run)
        return run
    }

    func execute(
        plan: FolderSyncBatchPlan,
        trigger: FolderSyncHistoryTrigger,
        configuration: FolderSyncRunConfiguration,
        onUpdate: (FolderSyncExecutionUpdate) -> Void
    ) async throws -> FolderSyncExecutionOutcome {
        let runID = UUID()
        let startedAt = Date()
        var items = plan.operations.map(makePendingHistoryItem)
        var historyRun = makeRun(
            id: runID,
            plan: plan,
            trigger: trigger,
            configuration: configuration,
            startedAt: startedAt,
            completedAt: startedAt,
            items: items
        )

        // Persist the full intended batch before the first destination mutation.
        // Unscheduled items are represented as cancelled until they complete.
        try historyStore.record(historyRun)

        var result = FolderSyncRunResult(
            pairs: plan.pairPlans.count,
            operations: plan.operationCount
        )
        let dispositions = plan.operationDispositions(
            overwriteExisting: configuration.overwriteExisting
        )
        var copiedBytes: Int64 = 0
        var completed = 0

        for (index, batchOperation) in plan.operations.enumerated() {
            guard !Task.isCancelled else {
                result.cancelled = completed < plan.operationCount
                break
            }

            let disposition = dispositions[batchOperation.key] ?? .apply
            let mutationResult: FolderSyncMutationResult
            switch disposition {
            case .apply:
                items[index] = markingOutcomeForReview(items[index])
                historyRun = makeRun(
                    id: runID,
                    plan: plan,
                    trigger: trigger,
                    configuration: configuration,
                    startedAt: startedAt,
                    completedAt: Date(),
                    items: items
                )
                // This is the history WAL entry for the one operation about to
                // mutate the destination. Later items remain durably cancelled.
                try historyStore.record(historyRun)
                mutationResult = await mutationService.apply(
                    batchOperation,
                    runID: runID,
                    overwriteExisting: configuration.overwriteExisting
                )
            case .skipExisting:
                mutationResult = FolderSyncMutationResult(
                    operationResult: .skippedExisting,
                    retentionMechanism: nil,
                    recoveryRecordID: nil
                )
            case .conflict:
                mutationResult = FolderSyncMutationResult(
                    operationResult: .failed(batchOperation.operation.relativePath),
                    retentionMechanism: nil,
                    recoveryRecordID: nil
                )
            }

            let itemOutcome = historyOutcome(
                mutationResult,
                operation: batchOperation.operation,
                disposition: disposition
            )
            items[index] = replacing(
                items[index],
                outcome: itemOutcome.outcome,
                message: itemOutcome.message,
                retryEligible: itemOutcome.retryEligible,
                recovery: recoveryReference(for: mutationResult)
            )
            apply(
                mutationResult.operationResult,
                operation: batchOperation.operation,
                to: &result,
                copiedBytes: &copiedBytes
            )
            completed += 1

            historyRun = makeRun(
                id: runID,
                plan: plan,
                trigger: trigger,
                configuration: configuration,
                startedAt: startedAt,
                completedAt: Date(),
                items: items
            )
            try historyStore.record(historyRun)
            onUpdate(
                FolderSyncExecutionUpdate(
                    operation: batchOperation,
                    completed: completed,
                    copiedBytes: copiedBytes,
                    result: result,
                    startedAt: startedAt
                )
            )

            if Task.isCancelled, completed < plan.operationCount {
                result.cancelled = true
                break
            }
        }

        historyRun = makeRun(
            id: runID,
            plan: plan,
            trigger: trigger,
            configuration: configuration,
            startedAt: startedAt,
            completedAt: Date(),
            items: items
        )
        try historyStore.record(historyRun)
        return FolderSyncExecutionOutcome(result: result, historyRun: historyRun)
    }

    func rollback(runID: UUID) async -> FolderSyncRollbackReport {
        await mutationService.rollback(runID: runID)
    }

    @discardableResult
    func recordRollback(
        runID: UUID,
        report: FolderSyncRollbackReport
    ) throws -> FolderSyncHistoryRun? {
        guard let run = historyStore.runs.first(where: { $0.id == runID }) else {
            return nil
        }
        let rollback = FolderSyncHistoryRollback(
            completedAt: Date(),
            items: report.items.map { item in
                FolderSyncHistoryRollbackItem(
                    recordID: item.recordID,
                    targetPath: item.targetPath,
                    outcome: item.outcome,
                    message: item.message
                )
            }
        )
        let updatedRun = FolderSyncHistoryRun(
            id: run.id,
            trigger: run.trigger,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            pairs: run.pairs,
            settings: run.settings,
            items: run.items,
            rollback: rollback
        )
        try historyStore.record(updatedRun)
        return updatedRun
    }

    func clearHistory() throws {
        try historyStore.clear()
    }

    private func makeRun(
        id: UUID,
        plan: FolderSyncBatchPlan,
        trigger: FolderSyncHistoryTrigger,
        configuration: FolderSyncRunConfiguration,
        startedAt: Date,
        completedAt: Date,
        items: [FolderSyncHistoryItem]
    ) -> FolderSyncHistoryRun {
        FolderSyncHistoryRun(
            id: id,
            trigger: trigger,
            startedAt: startedAt,
            completedAt: completedAt,
            pairs: plan.pairPlans.map { pairPlan in
                FolderSyncHistoryPairSnapshot(
                    id: pairPlan.pairID,
                    title: pairPlan.pairTitle,
                    originPath: pairPlan.plan.originRoot.path(percentEncoded: false),
                    destinationPath: pairPlan.plan.destinationRoot.path(percentEncoded: false)
                )
            },
            settings: FolderSyncHistorySettingsSnapshot(
                destinationLayout: configuration.destinationLayout,
                deleteDestinationItems: configuration.deleteDestinationItems,
                overwriteExisting: configuration.overwriteExisting,
                includedFileExtensions: configuration.includedFileExtensions?.sorted(),
                automaticSyncEnabled: configuration.autoSyncEnabled
            ),
            items: items
        )
    }

    private func makePendingHistoryItem(
        _ batchOperation: FolderSyncBatchOperation
    ) -> FolderSyncHistoryItem {
        let operation = batchOperation.operation
        return FolderSyncHistoryItem(
            id: UUID(),
            pairID: batchOperation.pairID,
            operationID: operation.id,
            kind: operation.kind,
            sourcePath: operation.sourceURL?.path(percentEncoded: false),
            destinationPath: operation.destinationURL.path(percentEncoded: false),
            relativePath: operation.relativePath,
            fileSizeBytes: operation.fileSizeBytes,
            outcome: .cancelled,
            outcomeMessage: "Not completed.",
            retryEligible: true,
            recovery: nil,
            outcomeRecordingState: .finalized
        )
    }

    private func markingOutcomeForReview(
        _ item: FolderSyncHistoryItem
    ) -> FolderSyncHistoryItem {
        FolderSyncHistoryItem(
            id: item.id,
            pairID: item.pairID,
            operationID: item.operationID,
            kind: item.kind,
            sourcePath: item.sourcePath,
            destinationPath: item.destinationPath,
            relativePath: item.relativePath,
            fileSizeBytes: item.fileSizeBytes,
            outcome: .cancelled,
            outcomeMessage:
                "This operation began, but its final outcome has not been durably recorded. Review the destination and recovery record before retrying.",
            retryEligible: false,
            recovery: nil,
            outcomeRecordingState: .requiresReview
        )
    }

    private func replacing(
        _ item: FolderSyncHistoryItem,
        outcome: FolderSyncHistoryItemOutcome,
        message: String,
        retryEligible: Bool,
        recovery: FolderSyncHistoryRecoveryReference?
    ) -> FolderSyncHistoryItem {
        FolderSyncHistoryItem(
            id: item.id,
            pairID: item.pairID,
            operationID: item.operationID,
            kind: item.kind,
            sourcePath: item.sourcePath,
            destinationPath: item.destinationPath,
            relativePath: item.relativePath,
            fileSizeBytes: item.fileSizeBytes,
            outcome: outcome,
            outcomeMessage: message,
            retryEligible: retryEligible,
            recovery: recovery,
            outcomeRecordingState: .finalized
        )
    }

    private func historyOutcome(
        _ result: FolderSyncMutationResult,
        operation: FolderSyncOperation,
        disposition: FolderSyncBatchOperationDisposition
    ) -> (outcome: FolderSyncHistoryItemOutcome, message: String, retryEligible: Bool) {
        switch result.operationResult {
        case .applied:
            return (.successful, successMessage(for: operation.kind), false)
        case .skippedExisting:
            return (.skipped, "Kept the existing destination item.", false)
        case .failed(let path):
            if disposition == .conflict {
                return (
                    .failed,
                    "Type conflict at \(path). Resolve the file/folder mismatch, then retry.",
                    true
                )
            }
            return (.failed, "Could not apply \(path).", true)
        }
    }

    private func successMessage(for kind: FolderSyncOperationKind) -> String {
        switch kind {
        case .createDirectory:
            "Created directory."
        case .copyNew:
            "Copied new item."
        case .copyUpdated:
            "Replaced destination item and retained its prior version."
        case .deleteFile, .deleteDirectory:
            "Removed destination item and retained it for recovery."
        }
    }

    private func recoveryReference(
        for result: FolderSyncMutationResult
    ) -> FolderSyncHistoryRecoveryReference? {
        guard let recordID = result.recoveryRecordID,
            let mechanism = result.retentionMechanism
        else { return nil }
        return FolderSyncHistoryRecoveryReference(
            recordID: recordID,
            mechanism: mechanism
        )
    }

    private func apply(
        _ itemResult: FolderSyncOperationResult,
        operation: FolderSyncOperation,
        to result: inout FolderSyncRunResult,
        copiedBytes: inout Int64
    ) {
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
    }
}
