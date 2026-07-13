import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

final class RecoverableFolderSyncMutationServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCopyNewJournalsIntentBeforeCreatingDestination() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("new take".utf8).write(to: source)

        let store = InspectingRecoveryStore { records in
            if records.last?.state == .intent {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyNew,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .applied)
        XCTAssertNil(result.retentionMechanism)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new take")
        XCTAssertTrue(store.didPersistIntent)
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .applied)
    }

    func testReviewedCopyNewNeverOverwritesDestinationThatAppearsBeforeApply() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("reviewed source".utf8).write(to: source)
        try Data("appeared after review".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyNew,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("take.txt"))
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8),
            "appeared after review"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path).isEmpty)
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testDeleteRetainsItemInTrashAndReportsMechanism() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let target = destination.appendingPathComponent("obsolete.txt")
        try Data("keep recoverable".utf8).write(to: target)
        let store = InspectingRecoveryStore { records in
            if records.last?.state == .intent {
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            }
        }
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .applied)
        XCTAssertEqual(result.retentionMechanism, .trash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let records = await service.recoveryRecords(runID: runID)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.state, .applied)
        XCTAssertEqual(record.retentionMechanism, .trash)
        let retainedPath = try XCTUnwrap(record.retainedPath)
        XCTAssertEqual(try String(contentsOfFile: retainedPath, encoding: .utf8), "keep recoverable")
    }

    func testDeleteFallsBackToSameVolumeQuarantineWhenTrashIsUnavailable() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = destination.appendingPathComponent("obsolete.txt")
        try Data("recoverable fallback".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .applied)
        XCTAssertEqual(result.retentionMechanism, .sameVolumeQuarantine)
        let records = await service.recoveryRecords(runID: runID)
        let retainedURL = URL(fileURLWithPath: try XCTUnwrap(records.first?.retainedPath))
        XCTAssertEqual(
            retainedURL.deletingLastPathComponent().lastPathComponent,
            runID.uuidString
        )
        XCTAssertEqual(
            retainedURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent,
            ".gphilcoder-sync-quarantine"
        )
        XCTAssertEqual(
            try String(contentsOf: retainedURL, encoding: .utf8),
            "recoverable fallback"
        )
    }

    func testOverwriteRetainsPriorTargetAndCopiesReplacement() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let source = origin.appendingPathComponent("mix.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("new mix".utf8).write(to: source)
        try Data("old mix".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .applied)
        XCTAssertEqual(result.retentionMechanism, .trash)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new mix")
        let records = await service.recoveryRecords(runID: runID)
        let retainedPath = try XCTUnwrap(records.first?.retainedPath)
        XCTAssertEqual(try String(contentsOfFile: retainedPath, encoding: .utf8), "old mix")
        XCTAssertEqual(records.first?.action, .replacedItem)
        XCTAssertEqual(records.first?.state, .applied)
    }

    func testReviewedCopyUpdatedDoesNotCreateMissingDestination() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("mix.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("reviewed replacement".utf8).write(to: source)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("mix.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testOverwriteFailureRestoresOriginalAndCleansTemporaryFiles() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let missingSource = origin.appendingPathComponent("missing.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("original mix".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: missingSource,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("mix.txt"))
        XCTAssertEqual(result.retentionMechanism, .trash)
        XCTAssertNil(result.recoveryRecordID)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original mix")
        let destinationItems = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            destinationItems.contains { $0.lastPathComponent.hasPrefix(".gphilcoder-sync-") }
        )
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testOverwriteJournalFinalizationFailureRestoresOriginal() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let source = origin.appendingPathComponent("mix.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: FailingSaveNumberRecoveryStore(failOnSave: 3),
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("mix.txt"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testCreateDirectoryJournalsAndCreatesOnlyRequestedDirectory() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = destination.appendingPathComponent("Audio", isDirectory: true)
        let store = InspectingRecoveryStore { records in
            if records.last?.state == .intent {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: UnavailableTrashBoundary()
        )

        let result = await service.apply(
            makeBatchOperation(
                kind: .createDirectory,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: UUID(),
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .applied)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(store.didPersistIntent)
    }

    func testRollbackRunsInReverseAndRemovesRunCreatedFileThenDirectory() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let createdDirectory = destination.appendingPathComponent("Audio", isDirectory: true)
        let copiedFile = createdDirectory.appendingPathComponent("take.txt")
        try Data("created during run".utf8).write(to: source)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()

        _ = await service.apply(
            makeBatchOperation(
                kind: .createDirectory,
                source: nil,
                destination: createdDirectory,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )
        _ = await service.apply(
            makeBatchOperation(
                kind: .copyNew,
                source: source,
                destination: copiedFile,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        let report = await service.rollback(runID: runID)

        XCTAssertEqual(report.restored, 2)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdDirectory.path))
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testVersionedJSONStoreReloadsAndRollbackRestoresDeletedItem() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = destination.appendingPathComponent("recover.txt")
        let journalURL = workspace.appendingPathComponent("recovery.json")
        try Data("survives reload".utf8).write(to: target)
        let runID = UUID()
        let firstService = try RecoverableFolderSyncMutationService(
            store: FolderSyncVersionedJSONRecoveryStore(fileURL: journalURL),
            trash: UnavailableTrashBoundary()
        )

        let applyResult = await firstService.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )
        XCTAssertEqual(applyResult.operationResult, .applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
        XCTAssertEqual((json as? [String: Any])?["version"] as? Int, 1)

        let reloadedService = try RecoverableFolderSyncMutationService(
            store: FolderSyncVersionedJSONRecoveryStore(fileURL: journalURL),
            trash: UnavailableTrashBoundary()
        )
        let reloadedRecords = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertEqual(reloadedRecords.count, 1)

        let report = await reloadedService.rollback(runID: runID)

        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "survives reload")
        let remaining = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRollbackRestoresPriorOverwrittenTarget() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let source = origin.appendingPathComponent("mix.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()
        _ = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        let report = await service.rollback(runID: runID)

        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
    }

    func testRollbackSkipsRunCreatedFileThatChangedAndKeepsRecoveryRecord() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("sync copy".utf8).write(to: source)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()
        _ = await service.apply(
            makeBatchOperation(
                kind: .copyNew,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )
        try Data("user changed it".utf8).write(to: target)

        let report = await service.rollback(runID: runID)

        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "user changed it")
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .recoveryFailed)
    }

    func testRollbackFailureLeavesMissingRetainedItemRecordAvailable() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = destination.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()
        _ = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )
        let appliedRecords = await service.recoveryRecords(runID: runID)
        let retainedPath = try XCTUnwrap(appliedRecords.first?.retainedPath)
        try FileManager.default.removeItem(atPath: retainedPath)

        let report = await service.rollback(runID: runID)

        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 1)
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .recoveryFailed)
    }

    func testDeleteDirectoryIsRetainedAndCanBeRolledBack() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = try makeDirectory("OldFolder", in: destination)
        try Data("nested".utf8).write(to: target.appendingPathComponent("file.txt"))
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteDirectory,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )
        let report = await service.rollback(runID: runID)

        XCTAssertEqual(result.operationResult, .applied)
        XCTAssertEqual(result.retentionMechanism, .sameVolumeQuarantine)
        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8),
            "nested"
        )
    }

    func testExistingCopyIsSkippedWithoutJournalWhenOverwriteIsDisabled() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("mix.txt")
        let target = destination.appendingPathComponent("mix.txt")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: target)
        let store = InspectingRecoveryStore()
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: UnavailableTrashBoundary()
        )

        let result = await service.apply(
            makeBatchOperation(
                kind: .copyUpdated,
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: UUID(),
            overwriteExisting: false
        )

        XCTAssertEqual(result.operationResult, .skippedExisting)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing")
        XCTAssertTrue(store.records.isEmpty)
    }

    func testJournalFailurePreventsDeleteMutation() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let target = destination.appendingPathComponent("keep.txt")
        try Data("must stay".utf8).write(to: target)
        let service = try RecoverableFolderSyncMutationService(
            store: FailingRecoveryStore(),
            trash: UnavailableTrashBoundary()
        )

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: UUID(),
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("keep.txt"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must stay")
    }

    func testDeleteFinalJournalFailureRestoresOriginalAndClearsRecoveryState() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let target = destination.appendingPathComponent("keep.txt")
        try Data("must survive finalization failure".utf8).write(to: target)
        let store = FailingSaveNumberRecoveryStore(failOnSave: 2)
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("keep.txt"))
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8),
            "must survive finalization failure"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path).isEmpty)
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)

        let reloadedService = try RecoverableFolderSyncMutationService(
            store: store,
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let reloadedRecords = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertTrue(reloadedRecords.isEmpty)
    }

    func testDeleteFinalizationFailureKeepsMemoryAlignedWithDurableIntent() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let target = destination.appendingPathComponent("keep.txt")
        try Data("restore despite unavailable journal".utf8).write(to: target)
        let store = FailAfterSaveNumberRecoveryStore(successfulSaveCount: 1)
        let service = try RecoverableFolderSyncMutationService(
            store: store,
            trash: MovingTrashBoundary(directory: trashDirectory)
        )
        let runID = UUID()

        let result = await service.apply(
            makeBatchOperation(
                kind: .deleteFile,
                source: nil,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("keep.txt"))
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8),
            "restore despite unavailable journal"
        )
        let memoryRecords = await service.recoveryRecords(runID: runID)
        let durableRecords = try store.load()
        XCTAssertEqual(memoryRecords, durableRecords)
        XCTAssertEqual(memoryRecords.first?.state, .intent)
        XCTAssertNil(memoryRecords.first?.retainedPath)
    }

    func testConcurrentCallersExecuteFilesystemMutationsSerially() async throws {
        let workspace = try makeTemporaryDirectory()
        let destination = try makeDirectory("Destination", in: workspace)
        let trashDirectory = try makeDirectory("Trash", in: workspace)
        let firstTarget = destination.appendingPathComponent("one.txt")
        let secondTarget = destination.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: firstTarget)
        try Data("two".utf8).write(to: secondTarget)
        let trash = ConcurrencyTrackingTrashBoundary(directory: trashDirectory)
        let service = try RecoverableFolderSyncMutationService(
            store: InspectingRecoveryStore(),
            trash: trash
        )
        let runID = UUID()
        let firstOperation = makeBatchOperation(
            kind: .deleteFile,
            source: nil,
            destination: firstTarget,
            destinationRoot: destination
        )
        let secondOperation = makeBatchOperation(
            kind: .deleteFile,
            source: nil,
            destination: secondTarget,
            destinationRoot: destination
        )

        async let first = service.apply(
            firstOperation,
            runID: runID,
            overwriteExisting: true
        )
        async let second = service.apply(
            secondOperation,
            runID: runID,
            overwriteExisting: true
        )
        let results = await [first, second]

        XCTAssertEqual(results.map(\.operationResult), [.applied, .applied])
        XCTAssertEqual(trash.maximumConcurrentCalls, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GPhilCoder-RecoverableSyncTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBatchOperation(
        kind: FolderSyncOperationKind,
        source: URL?,
        destination: URL,
        destinationRoot: URL
    ) -> FolderSyncBatchOperation {
        let operation = FolderSyncOperation(
            kind: kind,
            sourceURL: source,
            destinationURL: destination,
            relativePath: destination.lastPathComponent
        )
        let plan = FolderSyncPlan(
            originRoot: source?.deletingLastPathComponent() ?? destinationRoot,
            destinationRoot: destinationRoot,
            operations: [operation],
            operationCount: 1,
            copyCount: kind == .copyNew || kind == .copyUpdated ? 1 : 0,
            updatedCount: kind == .copyUpdated ? 1 : 0,
            createdDirectoryCount: kind == .createDirectory ? 1 : 0,
            deletedFileCount: kind == .deleteFile ? 1 : 0,
            deletedDirectoryCount: kind == .deleteDirectory ? 1 : 0,
            totalCopyBytes: 0,
            totalDeleteBytes: 0,
            scannedAt: Date()
        )
        return FolderSyncBatchOperation(
            pairPlan: FolderSyncPairPlan(pairID: UUID(), pairTitle: "Test Pair", plan: plan),
            operation: operation
        )
    }
}

private final class InspectingRecoveryStore: FolderSyncRecoveryJournalStore {
    private(set) var records: [FolderSyncRecoveryRecord] = []
    private(set) var didPersistIntent = false
    private let onSave: ([FolderSyncRecoveryRecord]) -> Void

    init(onSave: @escaping ([FolderSyncRecoveryRecord]) -> Void = { _ in }) {
        self.onSave = onSave
    }

    func load() throws -> [FolderSyncRecoveryRecord] {
        records
    }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        self.records = records
        if records.contains(where: { $0.state == .intent }) {
            didPersistIntent = true
        }
        onSave(records)
    }
}

private final class FailingRecoveryStore: FolderSyncRecoveryJournalStore {
    struct WriteFailure: Error {}

    func load() throws -> [FolderSyncRecoveryRecord] { [] }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        throw WriteFailure()
    }
}

private final class FailingSaveNumberRecoveryStore: FolderSyncRecoveryJournalStore {
    struct WriteFailure: Error {}
    private let failOnSave: Int
    private var saveCount = 0
    private var records: [FolderSyncRecoveryRecord] = []

    init(failOnSave: Int) {
        self.failOnSave = failOnSave
    }

    func load() throws -> [FolderSyncRecoveryRecord] { records }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        saveCount += 1
        if saveCount == failOnSave { throw WriteFailure() }
        self.records = records
    }
}

private final class FailAfterSaveNumberRecoveryStore: FolderSyncRecoveryJournalStore {
    struct WriteFailure: Error {}
    private let successfulSaveCount: Int
    private var saveCount = 0
    private var records: [FolderSyncRecoveryRecord] = []

    init(successfulSaveCount: Int) {
        self.successfulSaveCount = successfulSaveCount
    }

    func load() throws -> [FolderSyncRecoveryRecord] { records }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        saveCount += 1
        guard saveCount <= successfulSaveCount else { throw WriteFailure() }
        self.records = records
    }
}

private struct UnavailableTrashBoundary: FolderSyncTrashBoundary {
    struct Unavailable: Error {}

    func moveToTrash(_ url: URL) throws -> URL {
        throw Unavailable()
    }
}

private struct MovingTrashBoundary: FolderSyncTrashBoundary {
    let directory: URL

    func moveToTrash(_ url: URL) throws -> URL {
        let retainedURL = directory.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: retainedURL)
        return retainedURL
    }
}

private final class ConcurrencyTrackingTrashBoundary: FolderSyncTrashBoundary {
    let directory: URL
    private let lock = NSLock()
    private var activeCalls = 0
    private var maximumCalls = 0

    init(directory: URL) {
        self.directory = directory
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumCalls
    }

    func moveToTrash(_ url: URL) throws -> URL {
        lock.lock()
        activeCalls += 1
        maximumCalls = max(maximumCalls, activeCalls)
        lock.unlock()
        defer {
            lock.lock()
            activeCalls -= 1
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.01)
        let retainedURL = directory.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: retainedURL)
        return retainedURL
    }
}
