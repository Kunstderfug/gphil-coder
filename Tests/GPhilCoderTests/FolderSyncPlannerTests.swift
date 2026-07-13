import Foundation
import XCTest
@testable import GPhilCoderCore

final class FolderSyncPlannerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testBuildPlanCopiesNewFilesAndCreatesEmptyDirectories() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("Audio/Take 1/song.flac", in: origin, contents: "source")
        try FileManager.default.createDirectory(
            at: origin.appendingPathComponent("Empty/Child", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        XCTAssertEqual(plan.createdDirectoryCount, 4)
        XCTAssertEqual(plan.copyCount, 1)
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertEqual(plan.operations.map(\.relativePath), [
            "Audio",
            "Audio/Take 1",
            "Empty",
            "Empty/Child",
            "Audio/Take 1/song.flac"
        ])
        XCTAssertEqual(plan.operations.map(\.kind), [
            .createDirectory,
            .createDirectory,
            .createDirectory,
            .createDirectory,
            .copyNew
        ])
        XCTAssertTrue(
            plan.operations
                .filter { $0.kind == .createDirectory }
                .allSatisfy { $0.sourceEvidence?.isDirectory == true }
        )
        let copy = try XCTUnwrap(plan.operations.last)
        XCTAssertEqual(
            copy.sourceURL?.standardizedFileURL,
            origin.appendingPathComponent("Audio/Take 1/song.flac").standardizedFileURL
        )
        XCTAssertEqual(
            copy.destinationURL.standardizedFileURL,
            destination.appendingPathComponent("Audio/Take 1/song.flac").standardizedFileURL
        )
        XCTAssertNotNil(copy.sourceEvidence)
        XCTAssertNil(copy.destinationEvidence)
    }

    func testBuildPlanUpdatesDestinationWhenOriginSizeChanges() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("score.txt", in: origin, contents: "newer larger")
        try writeFile("score.txt", in: destination, contents: "old")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        XCTAssertEqual(plan.copyCount, 1)
        XCTAssertEqual(plan.updatedCount, 1)
        XCTAssertEqual(plan.operations.map(\.kind), [.copyUpdated])
        let operation = try XCTUnwrap(plan.operations.first)
        XCTAssertEqual(
            operation.sourceURL?.standardizedFileURL,
            origin.appendingPathComponent("score.txt").standardizedFileURL
        )
        XCTAssertEqual(
            operation.destinationURL.standardizedFileURL,
            destination.appendingPathComponent("score.txt").standardizedFileURL
        )
        XCTAssertEqual(operation.sourceEvidence?.fileSizeBytes, 12)
        XCTAssertEqual(operation.destinationEvidence?.fileSizeBytes, 3)
    }

    func testBuildPlanDeletesDestinationItemsMissingFromOriginWhenExplicitlyEnabled() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("keep.txt", in: origin, contents: "keep")
        try writeFile("keep.txt", in: destination, contents: "keep")
        try writeFile("Removed/file.txt", in: destination, contents: "delete")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: true
        )

        XCTAssertEqual(plan.deletedFileCount, 0)
        XCTAssertEqual(plan.deletedDirectoryCount, 1)
        XCTAssertEqual(plan.operations.map(\.kind), [.deleteDirectory])
        XCTAssertEqual(plan.operations.map(\.relativePath), ["Removed"])
        let operation = try XCTUnwrap(plan.operations.first)
        XCTAssertNil(operation.sourceURL)
        XCTAssertEqual(
            operation.destinationURL.standardizedFileURL,
            destination.appendingPathComponent("Removed").standardizedFileURL
        )
        XCTAssertEqual(operation.destinationEvidence?.isDirectory, true)
        XCTAssertEqual(operation.destinationEvidence?.descendantCount, 1)
    }

    func testDirectoryDeletionIncludesRecursiveDestinationBytesInThePlan() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("Removed/one.txt", in: destination, contents: "123")
        try writeFile("Removed/Nested/two.txt", in: destination, contents: "4567")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: true
        )

        XCTAssertEqual(plan.operations.map(\.kind), [.deleteDirectory])
        XCTAssertEqual(plan.operations.first?.fileSizeBytes, 7)
        XCTAssertEqual(plan.totalDeleteBytes, 7)
    }

    func testBuildPlanCanKeepDestinationOnlyItems() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("extra.txt", in: destination, contents: "destination only")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        XCTAssertFalse(plan.hasWork)
        XCTAssertTrue(plan.operations.isEmpty)
    }

    func testBuildPlanRejectsAnOriginThatIsNoLongerADirectory() throws {
        let workspace = try makeTemporaryDirectory()
        let origin = workspace.appendingPathComponent("Origin", isDirectory: true)
        let destination = workspace.appendingPathComponent("Destination", isDirectory: true)
        try "not a directory".write(to: origin, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try FolderSyncPlanner.buildPlan(
                originRoot: origin,
                destinationRoot: destination,
                syncDeletes: true
            )
        )
    }

    func testBuildPlanFiltersCopiedAndUpdatedFilesByExtension() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("Audio/song.wav", in: origin, contents: "audio")
        try writeFile("Docs/notes.txt", in: origin, contents: "notes")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            includedFileExtensions: ["wav"]
        )

        XCTAssertEqual(plan.copyCount, 1)
        XCTAssertEqual(plan.createdDirectoryCount, 1)
        XCTAssertEqual(plan.operations.map(\.relativePath), ["Audio", "Audio/song.wav"])
        XCTAssertEqual(plan.operations.map(\.kind), [.createDirectory, .copyNew])
        XCTAssertFalse(plan.operations.contains { operation in
            operation.relativePath == "Docs" || operation.relativePath.hasPrefix("Docs/")
        })
        let copy = try XCTUnwrap(plan.operations.last)
        XCTAssertEqual(
            copy.sourceURL?.standardizedFileURL,
            origin.appendingPathComponent("Audio/song.wav").standardizedFileURL
        )
        XCTAssertEqual(
            copy.destinationURL.standardizedFileURL,
            destination.appendingPathComponent("Audio/song.wav").standardizedFileURL
        )
    }

    func testBuildPlanFilteredDeletesPreserveExcludedDestinationFiles() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("keep.txt", in: destination, contents: "excluded")
        try writeFile("remove.wav", in: destination, contents: "included")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: true,
            includedFileExtensions: ["wav"]
        )

        XCTAssertEqual(plan.deletedFileCount, 1)
        XCTAssertEqual(plan.deletedDirectoryCount, 0)
        XCTAssertEqual(plan.operations.map(\.relativePath), ["remove.wav"])
        let deletion = try XCTUnwrap(plan.operations.first)
        XCTAssertEqual(deletion.kind, .deleteFile)
        XCTAssertNil(deletion.sourceURL)
        XCTAssertEqual(
            deletion.destinationURL.standardizedFileURL,
            destination.appendingPathComponent("remove.wav").standardizedFileURL
        )
        XCTAssertEqual(deletion.destinationEvidence?.fileSizeBytes, 8)
    }

    func testMultipleOriginsCanShareDestinationUsingOriginSubfolders() throws {
        let workspace = try makeTemporaryDirectory()
        let originA = workspace.appendingPathComponent("OriginA", isDirectory: true)
        let originB = workspace.appendingPathComponent("OriginB", isDirectory: true)
        let sharedDestination = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: originA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originB, withIntermediateDirectories: true)
        try writeFile("one.txt", in: originA, contents: "one")
        try writeFile("two.txt", in: originB, contents: "two")

        let targetA = sharedDestination.appendingPathComponent(originA.lastPathComponent, isDirectory: true)
        let targetB = sharedDestination.appendingPathComponent(originB.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: targetA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetB, withIntermediateDirectories: true)

        let firstPlan = try FolderSyncPlanner.buildPlan(
            originRoot: originA,
            destinationRoot: targetA
        )
        let secondPlan = try FolderSyncPlanner.buildPlan(
            originRoot: originB,
            destinationRoot: targetB
        )

        XCTAssertEqual(
            firstPlan.operations.map(\.destinationURL.standardizedFileURL),
            [targetA.appendingPathComponent("one.txt").standardizedFileURL]
        )
        XCTAssertEqual(
            secondPlan.operations.map(\.destinationURL.standardizedFileURL),
            [targetB.appendingPathComponent("two.txt").standardizedFileURL]
        )
        XCTAssertEqual(firstPlan.operations.map(\.kind), [.copyNew])
        XCTAssertEqual(secondPlan.operations.map(\.kind), [.copyNew])

        try writeFile("one.txt", in: targetA, contents: "one")
        try writeFile("two.txt", in: targetB, contents: "two")
        try FileManager.default.removeItem(at: originB.appendingPathComponent("two.txt"))
        let deletePlan = try FolderSyncPlanner.buildPlan(
            originRoot: originB,
            destinationRoot: targetB,
            syncDeletes: true
        )
        XCTAssertEqual(deletePlan.operations.map(\.kind), [.deleteFile])
        XCTAssertEqual(
            deletePlan.operations.map(\.destinationURL.standardizedFileURL),
            [targetB.appendingPathComponent("two.txt").standardizedFileURL]
        )
    }

    func testBuildPlanCapturesDestinationEvidenceWithoutMutatingIt() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("score.txt", in: origin, contents: "new larger")
        try writeFile("score.txt", in: destination, contents: "old")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        let update = try XCTUnwrap(plan.operations.first)
        XCTAssertEqual(update.kind, .copyUpdated)
        XCTAssertEqual(update.sourceEvidence?.fileSizeBytes, 10)
        XCTAssertEqual(update.destinationEvidence?.fileSizeBytes, 3)
        XCTAssertNotEqual(
            update.sourceEvidence?.contentSignature,
            update.destinationEvidence?.contentSignature
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("score.txt"),
                encoding: .utf8
            ),
            "old"
        )
    }

    func testBatchPlanKeepsEveryPairVisibleAndDerivesTotalsFromTheSameOperations() throws {
        let firstOrigin = try makeTemporaryDirectory()
        let firstDestination = try makeTemporaryDirectory()
        let secondOrigin = try makeTemporaryDirectory()
        let secondDestination = try makeTemporaryDirectory()
        try writeFile("first.txt", in: firstOrigin, contents: "first")
        try writeFile("second.txt", in: secondOrigin, contents: "second")

        let firstPairID = UUID()
        let secondPairID = UUID()
        let batch = FolderSyncBatchPlan(
            pairPlans: [
                FolderSyncPairPlan(
                    pairID: firstPairID,
                    pairTitle: "First -> Destination",
                    plan: try FolderSyncPlanner.buildPlan(
                        originRoot: firstOrigin,
                        destinationRoot: firstDestination,
                        syncDeletes: false
                    )
                ),
                FolderSyncPairPlan(
                    pairID: secondPairID,
                    pairTitle: "Second -> Destination",
                    plan: try FolderSyncPlanner.buildPlan(
                        originRoot: secondOrigin,
                        destinationRoot: secondDestination,
                        syncDeletes: false
                    )
                )
            ]
        )

        XCTAssertEqual(batch.operationCount, 2)
        XCTAssertEqual(batch.copyCount, 2)
        XCTAssertEqual(batch.deleteCount, 0)
        let preview = batch.preview(limit: 10)
        XCTAssertEqual(preview.groups.map(\.pairID), [firstPairID, secondPairID])
        XCTAssertEqual(preview.groups.map(\.totalOperationCount), [1, 1])
        XCTAssertEqual(preview.groups.map(\.visibleOperationCount), [1, 1])
        XCTAssertEqual(preview.groups.map(\.hiddenOperationCount), [0, 0])
        XCTAssertEqual(preview.totalOperationCount, batch.operations.count)
        XCTAssertEqual(preview.visibleOperationCount, 2)
        XCTAssertEqual(preview.hiddenOperationCount, 0)
    }

    func testBatchPreviewReservesARowForLaterWorkBearingPairsBeforeUsingRowBudget() {
        let firstPairID = UUID()
        let secondPairID = UUID()
        let firstPlan = makePlan(operationCount: 305, rootName: "First")
        let secondPlan = makePlan(operationCount: 2, rootName: "Second")
        let batch = FolderSyncBatchPlan(
            pairPlans: [
                FolderSyncPairPlan(
                    pairID: firstPairID,
                    pairTitle: "First -> Destination",
                    plan: firstPlan
                ),
                FolderSyncPairPlan(
                    pairID: secondPairID,
                    pairTitle: "Second -> Destination",
                    plan: secondPlan
                )
            ]
        )

        let preview = batch.preview(limit: 300)

        XCTAssertEqual(preview.groups.map(\.pairID), [firstPairID, secondPairID])
        XCTAssertEqual(preview.groups.map(\.totalOperationCount), [305, 2])
        XCTAssertEqual(preview.groups.map(\.visibleOperationCount), [299, 1])
        XCTAssertEqual(preview.groups.map(\.hiddenOperationCount), [6, 1])
        XCTAssertEqual(preview.totalOperationCount, 307)
        XCTAssertEqual(preview.visibleOperationCount, 300)
        XCTAssertEqual(preview.hiddenOperationCount, 7)
        XCTAssertEqual(
            preview.groups[1].operations.first?.operation.relativePath,
            "item-0.txt"
        )
    }

    func testBatchPreviewCarriesPairPlanningFailuresAndCannotBeApplied() {
        let origin = URL(fileURLWithPath: "/Origin")
        let destination = URL(fileURLWithPath: "/Destination")
        let failure = FolderSyncPairPlanningFailure(
            pairID: UUID(),
            pairTitle: "Origin -> Destination",
            originRoot: origin,
            destinationRoot: destination,
            errorDescription: "The folder could not be read."
        )
        let batch = FolderSyncBatchPlan(pairPlans: [], planningFailures: [failure])

        let preview = batch.preview(limit: 300)

        XCTAssertEqual(preview.planningFailures.map(\.id), [failure.id])
        XCTAssertEqual(preview.planningFailures.first?.originRoot, origin)
        XCTAssertEqual(preview.planningFailures.first?.destinationRoot, destination)
        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.isApplyable)
    }

    func testDirectoryOverFileConflictIsVisibleAndNeverPlannedAsADeletion() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("Blocked/child.txt", in: origin, contents: "new")
        try writeFile("Blocked", in: destination, contents: "existing file")
        let pairID = UUID()
        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: true
        )
        let batch = FolderSyncBatchPlan(
            pairPlans: [
                FolderSyncPairPlan(pairID: pairID, pairTitle: "Conflict", plan: plan)
            ]
        )

        XCTAssertFalse(plan.operations.contains { $0.kind == .deleteFile })
        XCTAssertEqual(plan.operations.first?.destinationEvidence?.isDirectory, false)
        XCTAssertEqual(
            batch.operations.map { batch.disposition(for: $0, overwriteExisting: true) },
            [.conflict, .conflict]
        )
    }

    func testFileOverDirectoryConflictProtectsTheDirectoryAndItsDescendants() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("Blocked", in: origin, contents: "new file")
        try writeFile("Blocked/keep.txt", in: destination, contents: "keep")
        let pairID = UUID()
        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: true
        )
        let batch = FolderSyncBatchPlan(
            pairPlans: [
                FolderSyncPairPlan(pairID: pairID, pairTitle: "Conflict", plan: plan)
            ]
        )

        XCTAssertEqual(plan.operations.map(\.kind), [.copyNew])
        XCTAssertEqual(plan.operations.first?.destinationEvidence?.isDirectory, true)
        XCTAssertEqual(
            batch.disposition(for: try XCTUnwrap(batch.operations.first), overwriteExisting: true),
            .conflict
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Blocked/keep.txt")),
            "keep"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makePlan(operationCount: Int, rootName: String) -> FolderSyncPlan {
        let origin = URL(fileURLWithPath: "/\(rootName)-Origin", isDirectory: true)
        let destination = URL(
            fileURLWithPath: "/\(rootName)-Destination",
            isDirectory: true
        )
        let operations = (0..<operationCount).map { index in
            FolderSyncOperation(
                kind: .copyNew,
                sourceURL: origin.appendingPathComponent("item-\(index).txt"),
                destinationURL: destination.appendingPathComponent("item-\(index).txt"),
                relativePath: "item-\(index).txt",
                fileSizeBytes: 1
            )
        }
        return FolderSyncPlan(
            originRoot: origin,
            destinationRoot: destination,
            operations: operations,
            operationCount: operations.count,
            copyCount: operations.count,
            updatedCount: 0,
            createdDirectoryCount: 0,
            deletedFileCount: 0,
            deletedDirectoryCount: 0,
            totalCopyBytes: Int64(operations.count),
            totalDeleteBytes: 0,
            scannedAt: Date()
        )
    }

    private func writeFile(_ relativePath: String, in root: URL, contents: String) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)?.write(to: url)
    }
}
