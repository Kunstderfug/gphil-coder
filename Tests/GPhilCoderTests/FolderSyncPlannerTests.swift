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

        for operation in plan.operations {
            XCTAssertEqual(FolderSyncPlanner.applyOperation(operation), .applied)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Audio/Take 1/song.flac").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Empty/Child").path
            )
        )
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

        XCTAssertEqual(FolderSyncPlanner.applyOperation(plan.operations[0]), .applied)
        let copied = try String(
            contentsOf: destination.appendingPathComponent("score.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(copied, "newer larger")
    }

    func testBuildPlanDeletesDestinationItemsMissingFromOriginByDefault() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("keep.txt", in: origin, contents: "keep")
        try writeFile("keep.txt", in: destination, contents: "keep")
        try writeFile("Removed/file.txt", in: destination, contents: "delete")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        XCTAssertEqual(plan.deletedFileCount, 0)
        XCTAssertEqual(plan.deletedDirectoryCount, 1)
        XCTAssertEqual(plan.operations.map(\.kind), [.deleteDirectory])
        XCTAssertEqual(plan.operations.map(\.relativePath), ["Removed"])

        XCTAssertEqual(FolderSyncPlanner.applyOperation(plan.operations[0]), .applied)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Removed").path
            )
        )
    }

    func testBuildPlanCanKeepDestinationOnlyItems() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("extra.txt", in: destination, contents: "destination only")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination,
            syncDeletes: false
        )

        XCTAssertFalse(plan.hasWork)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("extra.txt").path
            )
        )
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

        let firstPlan = try FolderSyncPlanner.buildPlan(
            originRoot: originA,
            destinationRoot: targetA
        )
        let secondPlan = try FolderSyncPlanner.buildPlan(
            originRoot: originB,
            destinationRoot: targetB
        )

        for operation in firstPlan.operations + secondPlan.operations {
            XCTAssertEqual(FolderSyncPlanner.applyOperation(operation), .applied)
        }

        XCTAssertEqual(
            try String(contentsOf: targetA.appendingPathComponent("one.txt"), encoding: .utf8),
            "one"
        )
        XCTAssertEqual(
            try String(contentsOf: targetB.appendingPathComponent("two.txt"), encoding: .utf8),
            "two"
        )

        try FileManager.default.removeItem(at: originB.appendingPathComponent("two.txt"))
        let deletePlan = try FolderSyncPlanner.buildPlan(
            originRoot: originB,
            destinationRoot: targetB
        )
        for operation in deletePlan.operations {
            XCTAssertEqual(FolderSyncPlanner.applyOperation(operation), .applied)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetA.appendingPathComponent("one.txt").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetB.appendingPathComponent("two.txt").path)
        )
    }

    func testApplyOperationSkipsExistingFilesWhenOverwriteIsOff() throws {
        let origin = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        try writeFile("score.txt", in: origin, contents: "new larger")
        try writeFile("score.txt", in: destination, contents: "old")

        let plan = try FolderSyncPlanner.buildPlan(
            originRoot: origin,
            destinationRoot: destination
        )

        XCTAssertEqual(
            FolderSyncPlanner.applyOperation(plan.operations[0], overwriteExisting: false),
            .skippedExisting
        )
        let retained = try String(
            contentsOf: destination.appendingPathComponent("score.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(retained, "old")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
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
