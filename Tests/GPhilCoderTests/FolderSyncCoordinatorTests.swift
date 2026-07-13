import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class FolderSyncCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearViewModelDefaultsForTests()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearViewModelDefaultsForTests()
        try super.tearDownWithError()
    }

    func testScanThenSyncCopiesUpdatesAndDeletesAcrossFolderPairs() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstOrigin = try makeDirectory("OriginA", in: workspace)
        let firstDestination = try makeDirectory("DestinationA", in: workspace)
        let secondOrigin = try makeDirectory("OriginB", in: workspace)
        let secondDestination = try makeDirectory("DestinationB", in: workspace)
        try writeFile("Audio/take.wav", in: firstOrigin, contents: "new audio")
        try writeFile("old.txt", in: firstDestination, contents: "delete me")
        try writeFile("Notes/readme.txt", in: secondOrigin, contents: "notes")

        let model = try makeFolderSyncModel()
        addPair(origin: firstOrigin, destination: firstDestination, to: model)
        addPair(origin: secondOrigin, destination: secondDestination, to: model)

        model.scanFolderSyncPlan()

        let scanned = await waitUntil {
            !model.isSyncScanning && model.syncScannedOperationCount > 0
        }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.syncScannedCopyCount, 2)
        XCTAssertEqual(model.syncScannedDeleteCount, 1)

        model.syncFoldersNow()

        let synced = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)
        XCTAssertEqual(
            try String(
                contentsOf: firstDestination.appendingPathComponent("Audio/take.wav"),
                encoding: .utf8
            ),
            "new audio"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: firstDestination.appendingPathComponent("old.txt").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: secondDestination.appendingPathComponent("Notes/readme.txt"),
                encoding: .utf8
            ),
            "notes"
        )
    }

    func testScanPublishesLabeledOperationsForEveryEnabledPair() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstOrigin = try makeDirectory("OriginA", in: workspace)
        let firstDestination = try makeDirectory("DestinationA", in: workspace)
        let secondOrigin = try makeDirectory("OriginB", in: workspace)
        let secondDestination = try makeDirectory("DestinationB", in: workspace)
        try writeFile("first.txt", in: firstOrigin, contents: "first")
        try writeFile("second.txt", in: secondOrigin, contents: "second")

        let model = try makeFolderSyncModel()
        model.syncDeleteDestinationItems = false
        addPair(origin: firstOrigin, destination: firstDestination, to: model)
        addPair(origin: secondOrigin, destination: secondDestination, to: model)
        let expectedPairIDs = Set(model.syncFolderPairs.map(\.id))

        model.scanFolderSyncPlan()

        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        XCTAssertEqual(Set(model.syncPreviewItems.map(\.pairID)), expectedPairIDs)
        XCTAssertEqual(model.syncPreviewItems.count, model.syncPendingOperationCount)
        XCTAssertEqual(
            Set(model.syncPreviewItems.map(\.pairTitle)),
            ["OriginA -> DestinationA", "OriginB -> DestinationB"]
        )
    }

    func testPairScanFailureRemainsVisibleAndBlocksTheIncompleteBatch() async throws {
        let workspace = try makeTemporaryDirectory()
        let healthyOrigin = try makeDirectory("HealthyOrigin", in: workspace)
        let healthyDestination = try makeDirectory("HealthyDestination", in: workspace)
        let failedOrigin = try makeDirectory("FailedOrigin", in: workspace)
        let failedDestination = try makeDirectory("FailedDestination", in: workspace)
        try writeFile("copy.txt", in: healthyOrigin, contents: "copy me")
        try writeFile("unreadable.txt", in: failedOrigin, contents: "scan me")

        let model = try makeFolderSyncModel()
        model.syncDeleteDestinationItems = false
        addPair(origin: healthyOrigin, destination: healthyDestination, to: model)
        addPair(origin: failedOrigin, destination: failedDestination, to: model)
        let failedPairID = try XCTUnwrap(model.syncFolderPairs.last?.id)

        model.scanFolderSyncPlan()
        try FileManager.default.removeItem(at: failedOrigin)
        try "not a directory".write(
            to: failedOrigin,
            atomically: true,
            encoding: .utf8
        )

        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        let batch = try XCTUnwrap(model.syncPlan)
        let failure = try XCTUnwrap(batch.planningFailures.first)
        XCTAssertEqual(failure.pairID, failedPairID)
        XCTAssertEqual(failure.pairTitle, "FailedOrigin -> FailedDestination")
        XCTAssertEqual(failure.originRoot.standardizedFileURL.path, failedOrigin.path)
        XCTAssertEqual(failure.destinationRoot.standardizedFileURL.path, failedDestination.path)
        XCTAssertFalse(failure.errorDescription.isEmpty)
        XCTAssertEqual(batch.operationCount, 1)
        XCTAssertFalse(batch.isApplyable)
        XCTAssertFalse(model.canApplyReviewedFolderSyncPlan)
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("could not scan"))

        model.syncFoldersNow()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: healthyDestination.appendingPathComponent("copy.txt").path
            )
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("incomplete"))
    }

    func testApplyRejectsAReviewedPlanWhenTheSourceChangesAfterScan() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = try writeFile("track.txt", in: origin, contents: "reviewed")

        let model = try makeFolderSyncModel()
        model.syncDeleteDestinationItems = false
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.syncPendingOperationCount, 1)

        try "changed after review".write(to: source, atomically: true, encoding: .utf8)
        model.syncFoldersNow()

        let finished = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(finished)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("track.txt").path
            )
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("changed"))
    }

    func testApplyRejectsSameSizeSourceChangesAfterReview() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = try writeFile("track.txt", in: origin, contents: "reviewed")

        let model = try makeFolderSyncModel()
        model.syncDeleteDestinationItems = false
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)

        try "changed!".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: source.path
        )
        model.syncFoldersNow()

        let finished = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(finished)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("track.txt").path
            )
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("changed"))
    }

    func testDeniedDestructiveReviewLeavesEveryDestinationItemUnchanged() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("update.txt", in: origin, contents: "new content")
        try writeFile("update.txt", in: destination, contents: "old")
        try writeFile("remove.txt", in: destination, contents: "keep on denial")

        let model = try makeFolderSyncModel()
        var destructiveSummary: FolderSyncDestructiveSummary?
        model.folderSyncDestructiveConfirmationHandler = { summary in
            destructiveSummary = summary
            return false
        }
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)

        model.syncFoldersNow()
        let finished = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(finished)

        XCTAssertEqual(destructiveSummary?.affectedPairCount, 1)
        XCTAssertEqual(destructiveSummary?.overwriteCount, 1)
        XCTAssertEqual(destructiveSummary?.deleteCount, 1)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("update.txt")),
            "old"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("remove.txt")),
            "keep on denial"
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("cancelled"))
    }

    func testAutomaticPlanWithADeletionPausesTheWholeBatchForReview() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("copy.txt", in: origin, contents: "copy later")
        try writeFile("delete.txt", in: destination, contents: "retain until review")

        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)
        model.syncAutoSyncEnabled = true

        model.handleFolderSyncOriginChange()

        let paused = await waitUntil(timeout: 5) {
            model.syncAutomaticPlanAwaitingReview
        }
        XCTAssertTrue(paused)
        XCTAssertEqual(model.syncPendingCopyCount, 1)
        XCTAssertEqual(model.syncPendingDeleteCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("copy.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("delete.txt").path
            )
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("review"))
    }

    func testRerunIsNoOpUntilOriginChanges() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let sourceFile = try writeFile("track.txt", in: origin, contents: "first")

        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)

        model.scanFolderSyncPlan()
        let initialScanFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(initialScanFinished)
        model.syncFoldersNow()
        let firstSyncFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(firstSyncFinished)
        XCTAssertEqual(model.statusMessage, "Folder sync finished, 1 copied, 0 deleted.")

        model.scanFolderSyncPlan()
        let noopScanFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(noopScanFinished)
        XCTAssertEqual(model.syncScannedOperationCount, 0)

        try "changed".write(to: sourceFile, atomically: true, encoding: .utf8)
        model.scanFolderSyncPlan()

        let changedScanFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(changedScanFinished)
        XCTAssertEqual(model.syncScannedCopyCount, 1)

        model.syncFoldersNow()
        let updateSyncFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(updateSyncFinished)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("track.txt"),
                encoding: .utf8
            ),
            "changed"
        )
    }

    func testDisabledFolderSyncPairIsIgnored() async throws {
        let workspace = try makeTemporaryDirectory()
        let enabledOrigin = try makeDirectory("EnabledOrigin", in: workspace)
        let enabledDestination = try makeDirectory("EnabledDestination", in: workspace)
        let disabledOrigin = try makeDirectory("DisabledOrigin", in: workspace)
        let disabledDestination = try makeDirectory("DisabledDestination", in: workspace)
        try writeFile("enabled.txt", in: enabledOrigin, contents: "enabled")
        try writeFile("disabled.txt", in: disabledOrigin, contents: "disabled")

        let model = try makeFolderSyncModel()
        addPair(origin: enabledOrigin, destination: enabledDestination, to: model)
        addPair(origin: disabledOrigin, destination: disabledDestination, to: model)
        guard let disabledPair = model.syncFolderPairs.last else {
            XCTFail("Expected disabled pair to be added.")
            return
        }
        model.setSyncFolderPair(disabledPair, enabled: false)

        model.scanFolderSyncPlan()
        let scanned = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        model.syncFoldersNow()

        let synced = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: enabledDestination.appendingPathComponent("enabled.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: disabledDestination.appendingPathComponent("disabled.txt").path
            )
        )
        XCTAssertEqual(model.syncFolderPairs.last?.state, .disabled)
    }

    func testCustomFolderSyncFilterCopiesAndDeletesOnlyMatchingExtensions() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: origin, contents: "audio")
        try writeFile("Docs/notes.txt", in: origin, contents: "notes")
        try writeFile("remove.wav", in: destination, contents: "remove")
        try writeFile("keep.txt", in: destination, contents: "keep")

        let model = try makeFolderSyncModel()
        model.syncFileFilter = .custom
        model.syncCustomFileExtensions = "wav"
        addPair(origin: origin, destination: destination, to: model)

        model.scanFolderSyncPlan()
        let scanned = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        model.syncFoldersNow()

        let synced = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Audio/take.wav").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Docs/notes.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("remove.wav").path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8),
            "keep"
        )
    }

    func testFolderSyncOverwriteOffSkipsExistingDestinationFile() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("track.txt", in: origin, contents: "newer larger")
        try writeFile("track.txt", in: destination, contents: "old")

        let model = try makeFolderSyncModel()
        model.syncOverwriteExisting = false
        addPair(origin: origin, destination: destination, to: model)

        model.scanFolderSyncPlan()
        let scanned = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.syncPendingCopyCount, 0)
        XCTAssertEqual(model.syncPendingSkipCount, 1)
        XCTAssertEqual(model.syncPendingApplyOperationCount, 0)
        model.syncFoldersNow()

        let synced = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("track.txt"), encoding: .utf8),
            "old"
        )
        XCTAssertEqual(model.statusMessage, "Folder sync finished, 0 copied, 0 deleted, 1 skipped.")
    }

    func testTypeConflictIsReportedWithoutChangingOrDeletingDestinationContents() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Blocked", in: origin, contents: "new file")
        try writeFile("Blocked/keep.txt", in: destination, contents: "keep")

        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.syncPendingOperationCount, 1)
        XCTAssertEqual(model.syncPendingConflictCount, 1)
        XCTAssertEqual(model.syncPendingCopyCount, 0)
        XCTAssertEqual(model.syncPendingDeleteCount, 0)

        model.syncFoldersNow()
        let finished = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(finished)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Blocked/keep.txt")),
            "keep"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Blocked").path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(model.syncHistory.first?.counts.failed, 1)
        XCTAssertTrue(model.syncRecoveryRecords.isEmpty)
    }

    func testApprovedDestructiveRunPersistsResultsAndRollbackRestoresPriorState() async throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("SyncState", in: workspace)
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("updated.txt", in: origin, contents: "new version")
        try writeFile("updated.txt", in: destination, contents: "prior version")
        try writeFile("deleted.txt", in: destination, contents: "restore me")

        let model = try makeFolderSyncModel(storageRoot: storageRoot)
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)

        model.syncFoldersNow()
        let synced = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)

        let run = try XCTUnwrap(model.syncHistory.first)
        XCTAssertEqual(run.counts.planned, 2)
        XCTAssertEqual(run.counts.successful, 2)
        XCTAssertEqual(run.counts.skipped, 0)
        XCTAssertEqual(run.counts.failed, 0)
        XCTAssertEqual(run.counts.cancelled, 0)
        XCTAssertEqual(run.items.count, run.counts.planned)
        XCTAssertEqual(Set(run.items.map(\.kind)), [.copyUpdated, .deleteFile])
        XCTAssertTrue(model.canRollbackFolderSyncRun(run))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("updated.txt")),
            "new version"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("deleted.txt").path
            )
        )

        let relaunchedBeforeRollback = EncoderViewModel(
            folderSyncStorageRoot: storageRoot,
            folderSyncTrashBoundary: UnavailableTrashBoundary()
        )
        let recoveryReloaded = await waitUntil {
            relaunchedBeforeRollback.syncRecoveryRecords.count == 2
        }
        XCTAssertTrue(recoveryReloaded)
        XCTAssertEqual(relaunchedBeforeRollback.syncHistory.first?.id, run.id)
        XCTAssertTrue(relaunchedBeforeRollback.canRollbackFolderSyncRun(run))

        model.rollbackFolderSyncRun(run.id)
        let rolledBack = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(rolledBack)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("updated.txt")),
            "prior version"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("deleted.txt")),
            "restore me"
        )
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("restored"))
        XCTAssertFalse(model.canRollbackFolderSyncRun(run))
        XCTAssertEqual(model.syncHistory.first?.rollback?.restored, 2)
        XCTAssertEqual(model.syncHistory.first?.rollback?.skipped, 0)
        XCTAssertEqual(model.syncHistory.first?.rollback?.failed, 0)

        let reloadedAfterRollback = EncoderViewModel(
            folderSyncStorageRoot: storageRoot,
            folderSyncTrashBoundary: UnavailableTrashBoundary()
        )
        XCTAssertEqual(reloadedAfterRollback.syncHistory.first?.id, run.id)
        XCTAssertEqual(reloadedAfterRollback.syncHistory.first?.rollback?.restored, 2)
    }

    func testManualNoChangeScanIsRetainedInHistory() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)

        model.scanFolderSyncPlan()

        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        let run = try XCTUnwrap(model.syncHistory.first)
        XCTAssertEqual(run.trigger, .manual)
        XCTAssertTrue(run.isNoChange)
        XCTAssertEqual(run.counts.planned, 0)
    }

    func testClearingHistoryKeepsOrphanedRecoveryAvailableForRollback() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("deleted.txt", in: destination, contents: "restore me")
        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitForFolderSyncToFinish(model)
        XCTAssertTrue(scanned)
        model.syncFoldersNow()
        let synced = await waitForFolderSyncToFinish(model)
        XCTAssertTrue(synced)
        let runID = try XCTUnwrap(model.syncHistory.first?.id)
        XCTAssertEqual(model.syncRecoveryRecords.count, 1)

        model.clearFolderSyncHistory()

        XCTAssertTrue(model.syncHistory.isEmpty)
        XCTAssertEqual(model.syncRecoveryRecords.count, 1)
        XCTAssertTrue(model.canRollbackFolderSyncRunID(runID))

        model.rollbackFolderSyncRun(runID)
        let rolledBack = await waitForFolderSyncToFinish(model)
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("deleted.txt")),
            "restore me"
        )
        XCTAssertTrue(model.syncHistory.isEmpty)
        XCTAssertTrue(model.syncRecoveryRecords.isEmpty)
    }

    func testAutomaticNoChangeRunIsRetainedWithAutomaticTrigger() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let model = try makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)
        model.syncAutoSyncEnabled = true

        model.handleFolderSyncOriginChange()

        let recorded = await waitUntil(timeout: 5) {
            model.syncHistory.first?.trigger == .automatic
        }
        XCTAssertTrue(recorded)
        XCTAssertTrue(model.syncHistory.first?.isNoChange == true)
        XCTAssertTrue(model.syncHistory.first?.settings.automaticSyncEnabled == true)
    }

    func testCancellationStopsSchedulingAndRetryIncludesOnlyUnfinishedChanges() async throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("SyncState", in: workspace)
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        for index in 0..<8 {
            try writeFile("remove-\(index).txt", in: destination, contents: "old \(index)")
        }

        let model = try makeFolderSyncModel(
            storageRoot: storageRoot,
            trashBoundary: SlowUnavailableTrashBoundary(delay: 0.15)
        )
        addPair(origin: origin, destination: destination, to: model)
        model.scanFolderSyncPlan()
        let scanned = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.syncPendingDeleteCount, 8)

        model.syncFoldersNow()
        let started = await waitUntil { model.isSyncing }
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 50_000_000)
        model.cancelFolderSync()
        let cancelled = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(cancelled)

        let cancelledRun = try XCTUnwrap(model.syncHistory.first)
        XCTAssertEqual(cancelledRun.counts.planned, 8)
        XCTAssertEqual(
            cancelledRun.counts.successful
                + cancelledRun.counts.skipped
                + cancelledRun.counts.failed
                + cancelledRun.counts.cancelled,
            cancelledRun.counts.planned
        )
        XCTAssertEqual(cancelledRun.counts.successful, 1)
        XCTAssertEqual(cancelledRun.counts.cancelled, 7)
        XCTAssertEqual(model.syncRecoveryRecords.count, 1)

        model.retryFolderSyncRun(cancelledRun.id)
        let retryPrepared = await waitUntil { !model.isFolderSyncBusy }
        XCTAssertTrue(retryPrepared)
        XCTAssertEqual(model.syncPendingOperationCount, cancelledRun.counts.cancelled)

        model.syncFoldersNow()
        let retryFinished = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(retryFinished)
        let retryRun = try XCTUnwrap(model.syncHistory.first)
        XCTAssertEqual(retryRun.trigger, .retry)
        XCTAssertEqual(retryRun.counts.planned, cancelledRun.counts.cancelled)
        XCTAssertEqual(retryRun.counts.successful, cancelledRun.counts.cancelled)
        XCTAssertEqual(cancelledRun.counts.successful, 1)
    }

    private func makeFolderSyncModel(
        storageRoot: URL? = nil,
        trashBoundary: FolderSyncTrashBoundary = UnavailableTrashBoundary()
    ) throws -> EncoderViewModel {
        let storageRoot = try storageRoot ?? makeTemporaryDirectory()
        let model = EncoderViewModel(
            folderSyncStorageRoot: storageRoot,
            folderSyncTrashBoundary: trashBoundary
        )
        model.completionNotificationsEnabled = false
        model.syncAutoSyncEnabled = false
        model.syncDestinationLayout = .destinationRoot
        model.syncFileFilter = .all
        model.syncOverwriteExisting = true
        model.syncDeleteDestinationItems = true
        model.folderSyncDestructiveConfirmationHandler = { _ in true }
        return model
    }

    private struct UnavailableTrashBoundary: FolderSyncTrashBoundary {
        func moveToTrash(_ url: URL) throws -> URL {
            throw CocoaError(.featureUnsupported)
        }
    }

    private struct SlowUnavailableTrashBoundary: FolderSyncTrashBoundary {
        let delay: TimeInterval

        func moveToTrash(_ url: URL) throws -> URL {
            Thread.sleep(forTimeInterval: delay)
            throw CocoaError(.featureUnsupported)
        }
    }

    private func addPair(origin: URL, destination: URL, to model: EncoderViewModel) {
        model.syncDraftOriginRoot = origin
        model.syncDraftDestinationRoot = destination
        model.addSyncFolderPair()
    }

    private func waitForFolderSyncToFinish(
        _ model: EncoderViewModel
    ) async -> Bool {
        await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ path: String, in root: URL, contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
