import Foundation
import GPhilCoderCore

@MainActor
enum MediaCopyTransactionExecutor {
    private struct StagedCandidate: Sendable {
        let candidate: MediaCopyCandidate
        let stagedURL: URL
        let evidence: MediaCopyPathEvidence
        let index: Int
    }

    fileprivate struct CommittedCandidate: Sendable {
        let candidate: MediaCopyCandidate
        let backupURL: URL?
        let installedEvidence: MediaCopyPathEvidence
    }

    private struct RollbackOutcome: Sendable {
        var complete = true
        var rolledBackCandidateCount = 0
        var removedDirectoryCount = 0
    }

    private enum RollbackError: Error {
        case directoryNotEmpty
    }

    struct RetainedTransaction: Sendable {
        fileprivate let committedCandidates: [CommittedCandidate]
        fileprivate let createdDirectories: [URL]
        fileprivate let transactionRoot: URL

        var recoveryPath: String { transactionRoot.path(percentEncoded: false) }
    }

    struct RetainedExecution: Sendable {
        let result: MediaCopyResult
        let transaction: RetainedTransaction?
    }

    static func execute(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution,
        isCancelled: () -> Bool = { Task.isCancelled },
        publishProgress: (MediaCopyProgress) -> Void
    ) async -> MediaCopyResult {
        await executeInternal(
            plan,
            conflictResolution: conflictResolution,
            isCancelled: isCancelled,
            retainSuccessfulTransaction: false,
            onRetainedTransaction: { _ in },
            publishProgress: publishProgress
        )
    }

    static func executeRetainingRollback(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution,
        publishProgress: (MediaCopyProgress) -> Void
    ) async -> RetainedExecution {
        var retainedTransaction: RetainedTransaction?
        let result = await executeInternal(
            plan,
            conflictResolution: conflictResolution,
            isCancelled: { Task.isCancelled },
            retainSuccessfulTransaction: true,
            onRetainedTransaction: { retainedTransaction = $0 },
            publishProgress: publishProgress
        )
        return RetainedExecution(result: result, transaction: retainedTransaction)
    }

    private static func executeInternal(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution,
        isCancelled: () -> Bool,
        retainSuccessfulTransaction: Bool,
        onRetainedTransaction: (RetainedTransaction) -> Void,
        publishProgress: (MediaCopyProgress) -> Void
    ) async -> MediaCopyResult {
        let candidates = plan.sourcePlans.flatMap(\.candidates)
        let startedAt = Date()
        var result = MediaCopyResult(total: candidates.count)
        var copiedBytes: Int64 = 0
        var expectedDestinationEvidence: [String: MediaCopyPathEvidence] = [:]
        for candidate in candidates {
            let key = plan.destinationEvidenceKey(for: candidate.destinationURL)
            if expectedDestinationEvidence[key] == nil {
                expectedDestinationEvidence[key] = plan.reviewedDestinationEvidence(
                    at: candidate.destinationURL
                )
            }
        }

        guard plan.canExecute else {
            result.failed = candidates.count
            result.failedNames = candidates.filter(\.hasDestinationConflict).map(\.relativePath)
            result.rejected = true
            return result
        }
        guard plan.matchesReviewedFilesystemEvidence() else {
            rejectStalePlan(candidates: candidates, result: &result)
            return result
        }

        let transactionRoot = plan.destinationRoot.appendingPathComponent(
            ".gphilcoder-copy-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedItemsRoot = transactionRoot.appendingPathComponent("items", isDirectory: true)
        let backupsRoot = transactionRoot.appendingPathComponent("backups", isDirectory: true)

        do {
            try await runFileOperation {
                try FileManager.default.createDirectory(
                    at: stagedItemsRoot,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: backupsRoot,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            result.failed = candidates.count
            result.failedNames = candidates.map(\.relativePath)
            result.rejected = true
            await recordCleanupOutcome(
                removeTransactionRoot(transactionRoot),
                transactionRoot: transactionRoot,
                result: &result
            )
            return result
        }

        var stagedCandidates: [StagedCandidate] = []
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() {
                result.cancelled = true
                await recordCleanupOutcome(
                    removeTransactionRoot(transactionRoot),
                    transactionRoot: transactionRoot,
                    result: &result
                )
                return result
            }

            publishProgress(
                makeProgress(
                    result: result,
                    copiedBytes: copiedBytes,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: startedAt,
                    currentName: candidate.name
                )
            )

            if conflictResolution == .skipExisting,
                FileManager.default.fileExists(atPath: candidate.destinationURL.path)
            {
                result.skippedExisting += 1
                continue
            }

            let stagedURL = stagedItemsRoot.appendingPathComponent(
                "\(index)-\(candidate.sourceURL.lastPathComponent)",
                isDirectory: candidate.isPackage
            )
            do {
                let evidence = try await runFileOperation {
                    try FileManager.default.copyItem(at: candidate.sourceURL, to: stagedURL)
                    return MediaCopyPathEvidence.capture(
                        at: stagedURL,
                        recursively: candidate.isPackage
                    )
                }
                stagedCandidates.append(
                    StagedCandidate(
                        candidate: candidate,
                        stagedURL: stagedURL,
                        evidence: evidence,
                        index: index
                    )
                )
            } catch {
                result.failed += 1
                result.failedNames.append(candidate.relativePath)
            }
        }

        if result.failed > 0 || isCancelled() {
            result.rejected = result.failed > 0
            result.cancelled = isCancelled()
            await recordCleanupOutcome(
                removeTransactionRoot(transactionRoot),
                transactionRoot: transactionRoot,
                result: &result
            )
            publishProgress(
                makeProgress(
                    result: result,
                    copiedBytes: 0,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: startedAt,
                    currentName: nil
                )
            )
            return result
        }

        guard plan.matchesReviewedFilesystemEvidence() else {
            rejectStalePlan(candidates: candidates, result: &result)
            await recordCleanupOutcome(
                removeTransactionRoot(transactionRoot),
                transactionRoot: transactionRoot,
                result: &result
            )
            return result
        }

        let reportedDirectoryPaths = Set(plan.sourcePlans.flatMap(\.plannedDirectoryPaths))
        var createdDirectories: [URL] = []
        for directoryURL in requiredDirectories(
            for: plan,
            candidates: stagedCandidates.map(\.candidate)
        ) {
            if isCancelled() { break }
            guard !FileManager.default.fileExists(atPath: directoryURL.path) else { continue }
            do {
                try await runFileOperation {
                    try FileManager.default.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: false
                    )
                }
                createdDirectories.append(directoryURL)
                if reportedDirectoryPaths.contains(directoryURL.standardizedFileURL.path) {
                    result.createdDirectories += 1
                }
            } catch {
                result.failedDirectories += 1
                result.failedDirectoryNames.append(directoryURL.path(percentEncoded: false))
                break
            }
        }

        if result.failedDirectories > 0 || isCancelled() {
            result.rejected = result.failedDirectories > 0
            result.cancelled = isCancelled()
            let outcome = await rollback(
                committedCandidates: [],
                createdDirectories: createdDirectories,
                transactionRoot: transactionRoot
            )
            applyRollbackOutcome(
                outcome,
                transactionRoot: transactionRoot,
                result: &result
            )
            return result
        }

        var committedCandidates: [CommittedCandidate] = []
        for staged in stagedCandidates {
            if isCancelled() { break }

            let candidate = staged.candidate
            let destinationKey = plan.destinationEvidenceKey(for: candidate.destinationURL)
            let currentDestinationEvidence = MediaCopyPathEvidence.capture(
                at: candidate.destinationURL,
                recursively: candidate.isPackage
            )
            guard expectedDestinationEvidence[destinationKey] == currentDestinationEvidence else {
                rejectStalePlan(candidates: candidates, result: &result)
                break
            }
            let destinationExists = FileManager.default.fileExists(
                atPath: candidate.destinationURL.path
            )
            if destinationExists && conflictResolution == .skipExisting {
                result.skippedExisting += 1
                continue
            }

            let backupURL = destinationExists
                ? backupsRoot.appendingPathComponent(
                    "\(staged.index)-backup",
                    isDirectory: candidate.isPackage
                )
                : nil
            do {
                if let backupURL {
                    try await runFileOperation {
                        try FileManager.default.moveItem(at: candidate.destinationURL, to: backupURL)
                    }
                }
                do {
                    try await runFileOperation {
                        try FileManager.default.moveItem(
                            at: staged.stagedURL,
                            to: candidate.destinationURL
                        )
                    }
                } catch {
                    let restored = await restoreBackupAfterFailedInstall(
                        backupURL: backupURL,
                        destinationURL: candidate.destinationURL
                    )
                    if !restored {
                        result.rollbackFailed = true
                        result.recoveryPath = transactionRoot.path(percentEncoded: false)
                    }
                    throw error
                }

                let installedEvidence = MediaCopyPathEvidence.capture(
                    at: candidate.destinationURL,
                    recursively: candidate.isPackage
                )
                committedCandidates.append(
                    CommittedCandidate(
                        candidate: candidate,
                        backupURL: backupURL,
                        installedEvidence: installedEvidence
                    )
                )
                expectedDestinationEvidence[destinationKey] = installedEvidence
                result.copied += 1
                copiedBytes += candidate.fileSizeBytes
            } catch {
                result.failed += 1
                result.failedNames.append(candidate.relativePath)
                result.rejected = true
                break
            }

            publishProgress(
                makeProgress(
                    result: result,
                    copiedBytes: copiedBytes,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: startedAt,
                    currentName: candidate.name
                )
            )
        }

        if result.rejected || isCancelled() {
            result.cancelled = isCancelled()
            let outcome = await rollback(
                committedCandidates: committedCandidates,
                createdDirectories: createdDirectories,
                transactionRoot: transactionRoot,
                preserveTransactionRoot: result.rollbackFailed
            )
            result.copied = max(0, result.copied - outcome.rolledBackCandidateCount)
            result.createdDirectories = max(
                0,
                result.createdDirectories - outcome.removedDirectoryCount
            )
            applyRollbackOutcome(
                outcome,
                transactionRoot: transactionRoot,
                result: &result
            )
            return result
        }

        result.appliedDestinationEvidence = destinationChangeEvidence(
            committedCandidates: committedCandidates,
            createdDirectories: createdDirectories,
            destinationRoot: plan.destinationRoot
        )
        if retainSuccessfulTransaction {
            onRetainedTransaction(
                RetainedTransaction(
                    committedCandidates: committedCandidates,
                    createdDirectories: createdDirectories,
                    transactionRoot: transactionRoot
                )
            )
        } else {
            await recordCleanupOutcome(
                removeTransactionRoot(transactionRoot),
                transactionRoot: transactionRoot,
                result: &result
            )
        }
        return result
    }

    static func rollbackRetainedTransaction(
        _ transaction: RetainedTransaction
    ) async -> Bool {
        let outcome = await rollback(
            committedCandidates: transaction.committedCandidates,
            createdDirectories: transaction.createdDirectories,
            transactionRoot: transaction.transactionRoot
        )
        return outcome.complete
    }

    static func finalizeRetainedTransaction(
        _ transaction: RetainedTransaction
    ) async -> Bool {
        await removeTransactionRoot(transaction.transactionRoot)
    }

    private static func makeProgress(
        result: MediaCopyResult,
        copiedBytes: Int64,
        totalBytes: Int64,
        startedAt: Date,
        currentName: String?
    ) -> MediaCopyProgress {
        MediaCopyProgress(
            completed: result.copied + result.skippedExisting + result.failed,
            total: result.total,
            copied: result.copied,
            skippedExisting: result.skippedExisting,
            failed: result.failed,
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            startedAt: startedAt,
            updatedAt: Date(),
            currentName: currentName
        )
    }

    private static func requiredDirectories(
        for plan: MediaCopyBatchPlan,
        candidates: [MediaCopyCandidate]
    ) -> [URL] {
        let rootPath = plan.destinationRoot.standardizedFileURL.path
        var paths = Set<String>()
        let desiredDirectories = candidates.map { $0.destinationURL.deletingLastPathComponent() }
            + plan.sourcePlans.flatMap { sourcePlan in
                sourcePlan.plannedDirectoryPaths.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            }

        for desiredDirectory in desiredDirectories {
            var directory = desiredDirectory.standardizedFileURL
            while directory.path != rootPath, directory.path.hasPrefix(rootPath + "/") {
                paths.insert(directory.path)
                directory.deleteLastPathComponent()
            }
        }

        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
    }

    private static func rollback(
        committedCandidates: [CommittedCandidate],
        createdDirectories: [URL],
        transactionRoot: URL,
        preserveTransactionRoot: Bool = false
    ) async -> RollbackOutcome {
        var outcome = RollbackOutcome(complete: !preserveTransactionRoot)
        for committed in committedCandidates.reversed() {
            let destinationURL = committed.candidate.destinationURL
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let unchanged = (try? await runFileOperation {
                    MediaCopyPathEvidence.capture(
                        at: destinationURL,
                        recursively: committed.candidate.isPackage
                    )
                }) == committed.installedEvidence
                guard unchanged else {
                    outcome.complete = false
                    continue
                }
                do {
                    try await runFileOperation {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                } catch {
                    outcome.complete = false
                    continue
                }
            }

            if let backupURL = committed.backupURL,
                FileManager.default.fileExists(atPath: backupURL.path)
            {
                do {
                    try await runFileOperation {
                        try FileManager.default.moveItem(at: backupURL, to: destinationURL)
                    }
                } catch {
                    outcome.complete = false
                    continue
                }
            }
            outcome.rolledBackCandidateCount += 1
        }

        for directoryURL in createdDirectories.reversed() {
            do {
                try await runFileOperation {
                    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
                    guard try FileManager.default.contentsOfDirectory(
                        atPath: directoryURL.path
                    ).isEmpty else {
                        throw RollbackError.directoryNotEmpty
                    }
                    try FileManager.default.removeItem(at: directoryURL)
                }
                outcome.removedDirectoryCount += 1
            } catch {
                outcome.complete = false
            }
        }

        if outcome.complete {
            let cleaned = await removeTransactionRoot(transactionRoot)
            if !cleaned {
                outcome.complete = false
            }
        }
        return outcome
    }

    private static func restoreBackupAfterFailedInstall(
        backupURL: URL?,
        destinationURL: URL
    ) async -> Bool {
        guard let backupURL else { return true }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return false }
        do {
            try await runFileOperation {
                try FileManager.default.moveItem(at: backupURL, to: destinationURL)
            }
            return true
        } catch {
            return false
        }
    }

    private static func applyRollbackOutcome(
        _ outcome: RollbackOutcome,
        transactionRoot: URL,
        result: inout MediaCopyResult
    ) {
        guard !outcome.complete else { return }
        result.rollbackFailed = true
        result.recoveryPath = transactionRoot.path(percentEncoded: false)
    }

    private static func recordCleanupOutcome(
        _ cleaned: Bool,
        transactionRoot: URL,
        result: inout MediaCopyResult
    ) {
        guard !cleaned else { return }
        result.rollbackFailed = true
        result.recoveryPath = transactionRoot.path(percentEncoded: false)
    }

    private static func rejectStalePlan(
        candidates: [MediaCopyCandidate],
        result: inout MediaCopyResult
    ) {
        result.failed = candidates.count
        result.failedNames = candidates.map(\.relativePath)
        result.rejected = true
        result.stalePlan = true
    }

    private static func destinationChangeEvidence(
        committedCandidates: [CommittedCandidate],
        createdDirectories: [URL],
        destinationRoot: URL
    ) -> [String: MediaCopyPathEvidence] {
        let rootPath = destinationRoot.standardizedFileURL.path
        let changedURLs = committedCandidates.map(\.candidate.destinationURL) + createdDirectories
        var paths = Set<String>()
        for changedURL in changedURLs {
            var url = changedURL.standardizedFileURL
            while url.path == rootPath || url.path.hasPrefix(rootPath + "/") {
                paths.insert(url.path)
                if url.path == rootPath { break }
                url.deleteLastPathComponent()
            }
        }
        return Dictionary(
            uniqueKeysWithValues: paths.map { path in
                (
                    path,
                    MediaCopyPathEvidence.capture(
                        at: URL(fileURLWithPath: path),
                        recursively: true
                    )
                )
            }
        )
    }

    private static func removeTransactionRoot(_ transactionRoot: URL) async -> Bool {
        do {
            try await runFileOperation {
                guard FileManager.default.fileExists(atPath: transactionRoot.path) else { return }
                try FileManager.default.removeItem(at: transactionRoot)
            }
            return true
        } catch {
            return false
        }
    }

    private static func runFileOperation<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}
