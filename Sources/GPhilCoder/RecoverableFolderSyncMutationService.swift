import Foundation
import GPhilCoderCore

actor RecoverableFolderSyncMutationService {
    private let store: FolderSyncRecoveryJournalStore
    private let trash: FolderSyncTrashBoundary
    private let fileManager: FileManager
    private var records: [FolderSyncRecoveryRecord]
    private var nextSequence: Int64

    init(
        store: FolderSyncRecoveryJournalStore,
        trash: FolderSyncTrashBoundary = FileManagerFolderSyncTrashBoundary(),
        fileManager: FileManager = .default
    ) throws {
        let loadedRecords = try store.load()
        self.store = store
        self.trash = trash
        self.fileManager = fileManager
        records = loadedRecords
        nextSequence = (loadedRecords.map(\.sequence).max() ?? 0) + 1
    }

    func apply(
        _ batchOperation: FolderSyncBatchOperation,
        runID: UUID,
        overwriteExisting: Bool
    ) -> FolderSyncMutationResult {
        switch batchOperation.operation.kind {
        case .copyNew, .copyUpdated:
            return applyCopy(
                batchOperation,
                runID: runID,
                overwriteExisting: overwriteExisting
            )
        case .deleteFile, .deleteDirectory:
            return applyDelete(batchOperation, runID: runID)
        case .createDirectory:
            return applyCreateDirectory(batchOperation, runID: runID)
        }
    }

    private func applyCreateDirectory(
        _ batchOperation: FolderSyncBatchOperation,
        runID: UUID
    ) -> FolderSyncMutationResult {
        let operation = batchOperation.operation
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: operation.destinationURL.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
                ? FolderSyncMutationResult(
                    operationResult: .applied,
                    retentionMechanism: nil,
                    recoveryRecordID: nil
                )
                : failedResult(for: operation)
        }

        let record = makeRecord(batchOperation, runID: runID, action: .createdItem)
        guard appendAndPersist(record) else {
            return failedResult(for: operation)
        }
        do {
            try fileManager.createDirectory(
                at: operation.destinationURL,
                withIntermediateDirectories: false
            )
            let fingerprint = try fingerprint(at: operation.destinationURL)
            guard updateRecord(record.id, state: .applied, fingerprint: fingerprint) else {
                return failedResult(for: operation, recordID: record.id)
            }
            return FolderSyncMutationResult(
                operationResult: .applied,
                retentionMechanism: nil,
                recoveryRecordID: record.id
            )
        } catch {
            if let contents = try? fileManager.contentsOfDirectory(
                at: operation.destinationURL,
                includingPropertiesForKeys: nil
            ), contents.isEmpty {
                try? fileManager.removeItem(at: operation.destinationURL)
            }
            removeRecord(record.id)
            return failedResult(for: operation)
        }
    }

    private func applyDelete(
        _ batchOperation: FolderSyncBatchOperation,
        runID: UUID
    ) -> FolderSyncMutationResult {
        let operation = batchOperation.operation
        guard fileManager.fileExists(atPath: operation.destinationURL.path) else {
            return FolderSyncMutationResult(
                operationResult: .applied,
                retentionMechanism: nil,
                recoveryRecordID: nil
            )
        }

        let record = makeRecord(batchOperation, runID: runID, action: .deletedItem)
        guard appendAndPersist(record) else {
            return failedResult(for: operation)
        }

        do {
            let retained = try retainItem(
                at: operation.destinationURL,
                destinationRoot: batchOperation.destinationRoot,
                recordID: record.id,
                runID: runID
            )
            guard updateRecord(
                record.id,
                state: .applied,
                retainedURL: retained.url,
                retentionMechanism: retained.mechanism
            ) else {
                let restored = restoreDeleteAfterJournalFinalizationFailure(
                    recordID: record.id,
                    retainedURL: retained.url,
                    retentionMechanism: retained.mechanism,
                    targetURL: operation.destinationURL
                )
                let hasRecoveryRecord = records.contains { $0.id == record.id }
                return FolderSyncMutationResult(
                    operationResult: .failed(operation.relativePath),
                    retentionMechanism: restored ? nil : retained.mechanism,
                    recoveryRecordID: hasRecoveryRecord ? record.id : nil
                )
            }
            return FolderSyncMutationResult(
                operationResult: .applied,
                retentionMechanism: retained.mechanism,
                recoveryRecordID: record.id
            )
        } catch {
            if fileManager.fileExists(atPath: operation.destinationURL.path) {
                removeRecord(record.id)
            } else {
                markRecoveryFailed(record.id, message: error.localizedDescription)
            }
            return failedResult(for: operation, recordID: record.id)
        }
    }

    func recoveryRecords(runID: UUID? = nil) -> [FolderSyncRecoveryRecord] {
        guard let runID else { return records }
        return records.filter { $0.runID == runID }
    }

    func rollback(runID: UUID) -> FolderSyncRollbackReport {
        let runRecords = records
            .filter { $0.runID == runID }
            .sorted { $0.sequence > $1.sequence }
        var results: [FolderSyncRollbackItemResult] = []

        for record in runRecords {
            guard markRollingBack(record.id) else {
                results.append(
                    rollbackResult(
                        record,
                        outcome: .failed,
                        message: "Could not persist rollback intent."
                    )
                )
                continue
            }
            results.append(rollback(record))
        }
        return FolderSyncRollbackReport(items: results)
    }

    private func rollback(_ record: FolderSyncRecoveryRecord) -> FolderSyncRollbackItemResult {
        switch record.action {
        case .createdItem:
            return rollbackCreatedItem(record)
        case .deletedItem, .replacedItem:
            return rollbackRetainedItem(record)
        }
    }

    private func rollbackCreatedItem(
        _ record: FolderSyncRecoveryRecord
    ) -> FolderSyncRollbackItemResult {
        let targetURL = URL(fileURLWithPath: record.targetPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            let discarded = removeRecord(record.id)
            return rollbackResult(
                record,
                outcome: discarded ? .skipped : .failed,
                message: discarded
                    ? "The run-created item was already absent."
                    : "The item was absent, but its recovery record could not be cleared."
            )
        }

        if isDirectory.boolValue {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: nil
                )
                guard contents.isEmpty else {
                    markRecoveryFailed(
                        record.id,
                        message: "The run-created directory is no longer empty."
                    )
                    return rollbackResult(
                        record,
                        outcome: .skipped,
                        message: "Kept the run-created directory because it is no longer empty."
                    )
                }
            } catch {
                markRecoveryFailed(record.id, message: error.localizedDescription)
                return rollbackResult(record, outcome: .failed, message: error.localizedDescription)
            }
        } else {
            guard let expected = record.appliedFingerprint else {
                markRecoveryFailed(
                    record.id,
                    message: "No post-mutation fingerprint is available."
                )
                return rollbackResult(
                    record,
                    outcome: .skipped,
                    message: "Kept the item because its run-created identity cannot be verified."
                )
            }
            do {
                guard try fingerprint(at: targetURL) == expected else {
                    markRecoveryFailed(
                        record.id,
                        message: "The run-created item changed after sync."
                    )
                    return rollbackResult(
                        record,
                        outcome: .skipped,
                        message: "Kept the item because it changed after sync."
                    )
                }
            } catch {
                markRecoveryFailed(record.id, message: error.localizedDescription)
                return rollbackResult(record, outcome: .failed, message: error.localizedDescription)
            }
        }

        do {
            try fileManager.removeItem(at: targetURL)
            guard removeRecord(record.id) else {
                return rollbackResult(
                    record,
                    outcome: .failed,
                    message: "Removed the run-created item, but could not clear its recovery record."
                )
            }
            return rollbackResult(
                record,
                outcome: .restored,
                message: "Removed the run-created item."
            )
        } catch {
            markRecoveryFailed(record.id, message: error.localizedDescription)
            return rollbackResult(record, outcome: .failed, message: error.localizedDescription)
        }
    }

    private func rollbackRetainedItem(
        _ record: FolderSyncRecoveryRecord
    ) -> FolderSyncRollbackItemResult {
        let targetURL = URL(fileURLWithPath: record.targetPath)
        guard let retainedPath = record.retainedPath else {
            if fileManager.fileExists(atPath: targetURL.path), record.state != .applied {
                let discarded = removeRecord(record.id)
                return rollbackResult(
                    record,
                    outcome: discarded ? .skipped : .failed,
                    message: discarded
                        ? "The recorded mutation had not retained or removed its target."
                        : "The stale recovery record could not be cleared."
                )
            }
            markRecoveryFailed(record.id, message: "The retained item location is unknown.")
            return rollbackResult(
                record,
                outcome: .failed,
                message: "The retained item location is unknown."
            )
        }
        let retainedURL = URL(fileURLWithPath: retainedPath)
        guard fileManager.fileExists(atPath: retainedURL.path) else {
            markRecoveryFailed(record.id, message: "The retained item is missing.")
            return rollbackResult(
                record,
                outcome: .failed,
                message: "The retained item is missing."
            )
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            guard record.action == .replacedItem else {
                markRecoveryFailed(
                    record.id,
                    message: "A new item now occupies the original path."
                )
                return rollbackResult(
                    record,
                    outcome: .skipped,
                    message: "Kept both items because the original path is occupied."
                )
            }
            guard let expected = record.appliedFingerprint else {
                markRecoveryFailed(
                    record.id,
                    message: "No post-mutation fingerprint is available."
                )
                return rollbackResult(
                    record,
                    outcome: .skipped,
                    message: "Kept both items because the replacement identity cannot be verified."
                )
            }
            do {
                guard try fingerprint(at: targetURL) == expected else {
                    markRecoveryFailed(
                        record.id,
                        message: "The replacement changed after sync."
                    )
                    return rollbackResult(
                        record,
                        outcome: .skipped,
                        message: "Kept both items because the replacement changed after sync."
                    )
                }
            } catch {
                markRecoveryFailed(record.id, message: error.localizedDescription)
                return rollbackResult(record, outcome: .failed, message: error.localizedDescription)
            }
            return rollbackReplacement(
                record,
                targetURL: targetURL,
                retainedURL: retainedURL
            )
        }

        do {
            try fileManager.moveItem(at: retainedURL, to: targetURL)
            cleanEmptyQuarantineDirectories(containing: retainedURL)
            guard removeRecord(record.id) else {
                return rollbackResult(
                    record,
                    outcome: .failed,
                    message: "Restored the item, but could not clear its recovery record."
                )
            }
            return rollbackResult(record, outcome: .restored, message: "Restored the retained item.")
        } catch {
            markRecoveryFailed(record.id, message: error.localizedDescription)
            return rollbackResult(record, outcome: .failed, message: error.localizedDescription)
        }
    }

    private func rollbackReplacement(
        _ record: FolderSyncRecoveryRecord,
        targetURL: URL,
        retainedURL: URL
    ) -> FolderSyncRollbackItemResult {
        let temporaryURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            ".gphilcoder-rollback-\(record.id.uuidString).tmp",
            isDirectory: false
        )
        do {
            try removeIfPresent(temporaryURL)
            try fileManager.moveItem(at: targetURL, to: temporaryURL)
            do {
                try fileManager.moveItem(at: retainedURL, to: targetURL)
            } catch {
                try? fileManager.moveItem(at: temporaryURL, to: targetURL)
                throw error
            }
            try fileManager.removeItem(at: temporaryURL)
            cleanEmptyQuarantineDirectories(containing: retainedURL)
            guard removeRecord(record.id) else {
                return rollbackResult(
                    record,
                    outcome: .failed,
                    message: "Restored the prior target, but could not clear its recovery record."
                )
            }
            return rollbackResult(record, outcome: .restored, message: "Restored the prior target.")
        } catch {
            if fileManager.fileExists(atPath: targetURL.path) {
                try? removeIfPresent(temporaryURL)
            }
            let message = fileManager.fileExists(atPath: temporaryURL.path)
                ? "\(error.localizedDescription) Replacement retained at \(temporaryURL.path)."
                : error.localizedDescription
            markRecoveryFailed(record.id, message: message)
            return rollbackResult(record, outcome: .failed, message: message)
        }
    }

    private func rollbackResult(
        _ record: FolderSyncRecoveryRecord,
        outcome: FolderSyncRollbackOutcome,
        message: String
    ) -> FolderSyncRollbackItemResult {
        FolderSyncRollbackItemResult(
            recordID: record.id,
            targetPath: record.targetPath,
            outcome: outcome,
            message: message
        )
    }

    private func applyCopy(
        _ batchOperation: FolderSyncBatchOperation,
        runID: UUID,
        overwriteExisting: Bool
    ) -> FolderSyncMutationResult {
        let operation = batchOperation.operation
        guard let sourceURL = operation.sourceURL else {
            return failedResult(for: operation)
        }

        var isDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(
            atPath: operation.destinationURL.path,
            isDirectory: &isDirectory
        )
        if destinationExists, operation.kind == .copyNew {
            return failedResult(for: operation)
        }
        if !destinationExists, operation.kind == .copyUpdated {
            return failedResult(for: operation)
        }
        guard !destinationExists || !isDirectory.boolValue else {
            return failedResult(for: operation)
        }
        if destinationExists, !overwriteExisting {
            return FolderSyncMutationResult(
                operationResult: .skippedExisting,
                retentionMechanism: nil,
                recoveryRecordID: nil
            )
        }
        if destinationExists {
            return applyOverwrite(
                batchOperation,
                sourceURL: sourceURL,
                runID: runID
            )
        }

        let record = makeRecord(
            batchOperation,
            runID: runID,
            action: .createdItem
        )
        guard appendAndPersist(record) else {
            return failedResult(for: operation)
        }

        let temporaryURL = temporaryCopyURL(for: operation.destinationURL, recordID: record.id)
        let fingerprint: FolderSyncRecoveryFingerprint
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            fingerprint = try self.fingerprint(at: temporaryURL)
        } catch {
            try? removeIfPresent(temporaryURL)
            removeRecord(record.id)
            let hasRecoveryRecord = records.contains { $0.id == record.id }
            return failedResult(
                for: operation,
                recordID: hasRecoveryRecord ? record.id : nil
            )
        }

        guard updateRecord(record.id, state: .intent, fingerprint: fingerprint) else {
            try? removeIfPresent(temporaryURL)
            removeRecord(record.id)
            let hasRecoveryRecord = records.contains { $0.id == record.id }
            return failedResult(
                for: operation,
                recordID: hasRecoveryRecord ? record.id : nil
            )
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: operation.destinationURL)
        } catch {
            try? removeIfPresent(temporaryURL)
            removeRecord(record.id)
            let hasRecoveryRecord = records.contains { $0.id == record.id }
            return failedResult(
                for: operation,
                recordID: hasRecoveryRecord ? record.id : nil
            )
        }

        guard updateRecord(record.id, state: .applied, fingerprint: fingerprint) else {
            restoreCreatedItemAfterJournalFinalizationFailure(
                recordID: record.id,
                targetURL: operation.destinationURL,
                expectedFingerprint: fingerprint
            )
            let hasRecoveryRecord = records.contains { $0.id == record.id }
            return failedResult(
                for: operation,
                recordID: hasRecoveryRecord ? record.id : nil
            )
        }
        return FolderSyncMutationResult(
            operationResult: .applied,
            retentionMechanism: nil,
            recoveryRecordID: record.id
        )
    }

    private func applyOverwrite(
        _ batchOperation: FolderSyncBatchOperation,
        sourceURL: URL,
        runID: UUID
    ) -> FolderSyncMutationResult {
        let operation = batchOperation.operation
        let record = makeRecord(batchOperation, runID: runID, action: .replacedItem)
        guard appendAndPersist(record) else {
            return failedResult(for: operation)
        }

        let retained: (url: URL, mechanism: FolderSyncRetentionMechanism)
        do {
            retained = try retainItem(
                at: operation.destinationURL,
                destinationRoot: batchOperation.destinationRoot,
                recordID: record.id,
                runID: runID
            )
        } catch {
            if fileManager.fileExists(atPath: operation.destinationURL.path) {
                removeRecord(record.id)
            } else {
                markRecoveryFailed(record.id, message: error.localizedDescription)
            }
            return failedResult(for: operation, recordID: record.id)
        }

        guard updateRecord(
            record.id,
            state: .retained,
            retainedURL: retained.url,
            retentionMechanism: retained.mechanism
        ) else {
            _ = restoreFailedOverwrite(
                recordID: record.id,
                retainedURL: retained.url,
                targetURL: operation.destinationURL
            )
            return FolderSyncMutationResult(
                operationResult: .failed(operation.relativePath),
                retentionMechanism: retained.mechanism,
                recoveryRecordID: record.id
            )
        }

        let temporaryURL = temporaryCopyURL(for: operation.destinationURL, recordID: record.id)
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: operation.destinationURL)
            let fingerprint = try fingerprint(at: operation.destinationURL)
            guard updateRecord(record.id, state: .applied, fingerprint: fingerprint) else {
                let restored = restoreFailedOverwrite(
                    recordID: record.id,
                    retainedURL: retained.url,
                    targetURL: operation.destinationURL
                )
                return FolderSyncMutationResult(
                    operationResult: .failed(operation.relativePath),
                    retentionMechanism: retained.mechanism,
                    recoveryRecordID: restored ? nil : record.id
                )
            }
            return FolderSyncMutationResult(
                operationResult: .applied,
                retentionMechanism: retained.mechanism,
                recoveryRecordID: record.id
            )
        } catch {
            try? removeIfPresent(temporaryURL)
            let restored = restoreFailedOverwrite(
                recordID: record.id,
                retainedURL: retained.url,
                targetURL: operation.destinationURL
            )
            if !restored {
                markRecoveryFailed(record.id, message: error.localizedDescription)
            }
            return FolderSyncMutationResult(
                operationResult: .failed(operation.relativePath),
                retentionMechanism: retained.mechanism,
                recoveryRecordID: restored ? nil : record.id
            )
        }
    }

    private func restoreFailedOverwrite(
        recordID: UUID,
        retainedURL: URL,
        targetURL: URL
    ) -> Bool {
        do {
            try removeIfPresent(targetURL)
            try fileManager.moveItem(at: retainedURL, to: targetURL)
            cleanEmptyQuarantineDirectories(containing: retainedURL)
            removeRecord(recordID)
            return !records.contains(where: { $0.id == recordID })
        } catch {
            markRecoveryFailed(recordID, message: error.localizedDescription)
            return false
        }
    }

    private func restoreCreatedItemAfterJournalFinalizationFailure(
        recordID: UUID,
        targetURL: URL,
        expectedFingerprint: FolderSyncRecoveryFingerprint
    ) {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            removeRecord(recordID)
            return
        }

        do {
            guard try fingerprint(at: targetURL) == expectedFingerprint else {
                markRecoveryFailed(
                    recordID,
                    message: "The newly copied item changed before recovery could remove it."
                )
                return
            }
            try fileManager.removeItem(at: targetURL)
            removeRecord(recordID)
        } catch {
            markRecoveryFailed(recordID, message: error.localizedDescription)
        }
    }

    private func makeRecord(
        _ batchOperation: FolderSyncBatchOperation,
        runID: UUID,
        action: FolderSyncRecoveryRecord.Action
    ) -> FolderSyncRecoveryRecord {
        defer { nextSequence += 1 }
        return FolderSyncRecoveryRecord(
            id: UUID(),
            runID: runID,
            sequence: nextSequence,
            operationID: batchOperation.id,
            operationKind: batchOperation.operation.kind,
            action: action,
            destinationRootPath: batchOperation.destinationRoot.standardizedFileURL.path,
            targetPath: batchOperation.operation.destinationURL.standardizedFileURL.path,
            sourcePath: batchOperation.operation.sourceURL?.standardizedFileURL.path,
            retainedPath: nil,
            retentionMechanism: nil,
            appliedFingerprint: nil,
            state: .intent,
            failureMessage: nil
        )
    }

    private func appendAndPersist(_ record: FolderSyncRecoveryRecord) -> Bool {
        records.append(record)
        do {
            try store.save(records)
            return true
        } catch {
            records.removeAll { $0.id == record.id }
            return false
        }
    }

    private func updateRecord(
        _ id: UUID,
        state: FolderSyncRecoveryRecord.State,
        fingerprint: FolderSyncRecoveryFingerprint? = nil,
        retainedURL: URL? = nil,
        retentionMechanism: FolderSyncRetentionMechanism? = nil
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let priorRecord = records[index]
        records[index].state = state
        if let fingerprint {
            records[index].appliedFingerprint = fingerprint
        }
        if let retainedURL {
            records[index].retainedPath = retainedURL.standardizedFileURL.path
        }
        if let retentionMechanism {
            records[index].retentionMechanism = retentionMechanism
        }
        do {
            try store.save(records)
            return true
        } catch {
            records[index] = priorRecord
            return false
        }
    }

    private func restoreDeleteAfterJournalFinalizationFailure(
        recordID: UUID,
        retainedURL: URL,
        retentionMechanism: FolderSyncRetentionMechanism,
        targetURL: URL
    ) -> Bool {
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            persistRetainedRecoveryFailure(
                recordID: recordID,
                retainedURL: retainedURL,
                retentionMechanism: retentionMechanism,
                message: "The original path became occupied before the retained item could be restored."
            )
            return false
        }

        do {
            try fileManager.moveItem(at: retainedURL, to: targetURL)
            cleanEmptyQuarantineDirectories(containing: retainedURL)
            if !removeRecord(recordID) {
                markRecoveryFailed(
                    recordID,
                    message: "The retained item was restored, but its recovery intent could not be cleared."
                )
            }
            return true
        } catch {
            persistRetainedRecoveryFailure(
                recordID: recordID,
                retainedURL: retainedURL,
                retentionMechanism: retentionMechanism,
                message: error.localizedDescription
            )
            return false
        }
    }

    private func persistRetainedRecoveryFailure(
        recordID: UUID,
        retainedURL: URL,
        retentionMechanism: FolderSyncRetentionMechanism,
        message: String
    ) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let priorRecord = records[index]
        records[index].state = .recoveryFailed
        records[index].retainedPath = retainedURL.standardizedFileURL.path
        records[index].retentionMechanism = retentionMechanism
        records[index].failureMessage = message
        do {
            try store.save(records)
        } catch {
            records[index] = priorRecord
        }
    }

    private func markRecoveryFailed(_ id: UUID, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let priorRecord = records[index]
        records[index].state = .recoveryFailed
        records[index].failureMessage = message
        do {
            try store.save(records)
        } catch {
            records[index] = priorRecord
        }
    }

    private func markRollingBack(_ id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let priorState = records[index].state
        records[index].state = .rollingBack
        records[index].failureMessage = nil
        do {
            try store.save(records)
            return true
        } catch {
            records[index].state = priorState
            return false
        }
    }

    @discardableResult
    private func removeRecord(_ id: UUID) -> Bool {
        let priorRecords = records
        records.removeAll { $0.id == id }
        do {
            try store.save(records)
            return true
        } catch {
            records = priorRecords
            return false
        }
    }

    private func temporaryCopyURL(for destinationURL: URL, recordID: UUID) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".gphilcoder-sync-\(recordID.uuidString).tmp",
            isDirectory: false
        )
    }

    private func retainItem(
        at originalURL: URL,
        destinationRoot: URL,
        recordID: UUID,
        runID: UUID
    ) throws -> (url: URL, mechanism: FolderSyncRetentionMechanism) {
        do {
            return (try trash.moveToTrash(originalURL), .trash)
        } catch {
            let quarantineRoot = destinationRoot.deletingLastPathComponent()
                .appendingPathComponent(".gphilcoder-sync-quarantine", isDirectory: true)
            let runDirectory = quarantineRoot
                .appendingPathComponent(destinationRoot.lastPathComponent, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let quarantineURL = runDirectory.appendingPathComponent(
                "\(recordID.uuidString)-\(originalURL.lastPathComponent)",
                isDirectory: false
            )
            try fileManager.moveItem(at: originalURL, to: quarantineURL)
            return (quarantineURL, .sameVolumeQuarantine)
        }
    }

    private func cleanEmptyQuarantineDirectories(containing retainedURL: URL) {
        let marker = ".gphilcoder-sync-quarantine"
        guard retainedURL.pathComponents.contains(marker) else { return }
        var directory = retainedURL.deletingLastPathComponent()
        while true {
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ),
                contents.isEmpty
            else { return }
            let isRoot = directory.lastPathComponent == marker
            try? fileManager.removeItem(at: directory)
            if isRoot { return }
            directory.deleteLastPathComponent()
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fingerprint(at url: URL) throws -> FolderSyncRecoveryFingerprint {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let isDirectory = values.isDirectory == true
        return FolderSyncRecoveryFingerprint(
            isDirectory: isDirectory,
            fileSizeBytes: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            contentSignature: isDirectory ? nil : try fileContentSignature(at: url)
        )
    }

    private func fileContentSignature(at url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var signature: UInt64 = 14_695_981_039_346_656_037
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            for byte in data {
                signature ^= UInt64(byte)
                signature &*= 1_099_511_628_211
            }
        }
        return signature
    }

    private func failedResult(
        for operation: FolderSyncOperation,
        recordID: UUID? = nil
    ) -> FolderSyncMutationResult {
        FolderSyncMutationResult(
            operationResult: .failed(operation.relativePath),
            retentionMechanism: nil,
            recoveryRecordID: recordID
        )
    }
}
