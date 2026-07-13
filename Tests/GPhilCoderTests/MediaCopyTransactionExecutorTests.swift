import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

@MainActor
final class MediaCopyTransactionExecutorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCancellationAfterFirstCommitRestoresOriginalDestination() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/a.wav", in: source, contents: "new a")
        try writeFile("Audio/b.wav", in: source, contents: "new b")
        try writeFile("Source/Audio/a.wav", in: destination, contents: "old a")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
        var shouldCancel = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            isCancelled: { shouldCancel },
            publishProgress: { progress in
                if progress.copied == 1 {
                    shouldCancel = true
                }
            }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/a.wav"),
                encoding: .utf8
            ),
            "old a"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/Audio/b.wav").path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testPackageCommitsAsOneCompleteDestinationItem() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Session.app/Contents/Info.plist", in: source, contents: "metadata")
        try writeFile("Session.app/Contents/Resources/payload.dat", in: source, contents: "payload")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .all
            )
        )

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .skipExisting,
            publishProgress: { _ in }
        )

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent(
                    "Source/Session.app/Contents/Info.plist"
                ),
                encoding: .utf8
            ),
            "metadata"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent(
                    "Source/Session.app/Contents/Resources/payload.dat"
                ),
                encoding: .utf8
            ),
            "payload"
        )
    }

    func testSourceDisappearingAfterPlanningRejectsWholeBatchWithoutDestinationChanges() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "audio")
        try writeFile("Audio/other.wav", in: source, contents: "other")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
        try FileManager.default.removeItem(
            at: source.appendingPathComponent("Audio/take.wav")
        )

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .skipExisting,
            publishProgress: { _ in }
        )

        XCTAssertEqual(result.failed, 2)
        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/Audio").path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testCancellationPreservesExternallyChangedDestinationAndRetainsBackup() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/a.wav", in: source, contents: "new a")
        try writeFile("Audio/b.wav", in: source, contents: "new b")
        try writeFile("Source/Audio/a.wav", in: destination, contents: "old a")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
        var shouldCancel = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            isCancelled: { shouldCancel },
            publishProgress: { progress in
                guard progress.copied == 1 else { return }
                try? "external edit".write(
                    to: destination.appendingPathComponent("Source/Audio/a.wav"),
                    atomically: true,
                    encoding: .utf8
                )
                shouldCancel = true
            }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.rollbackFailed)
        XCTAssertNotNil(result.recoveryPath)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/a.wav"),
                encoding: .utf8
            ),
            "external edit"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(result.recoveryPath))
        )
    }

    func testSourceChangedAfterPlanningRejectsWithoutDestinationChanges() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "reviewed")

        let plan = try makeAudioPlan(source: source, destination: destination)
        try writeFile("Audio/take.wav", in: source, contents: "changed after review")

        let result = await execute(plan, conflictResolution: .replaceExisting)

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/Audio/take.wav").path
            )
        )
    }

    func testDestinationCreatedAfterPlanningRejectsInsteadOfReplacingIt() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "source")

        let plan = try makeAudioPlan(source: source, destination: destination)
        try writeFile("Source/Audio/take.wav", in: destination, contents: "external")

        let result = await execute(plan, conflictResolution: .replaceExisting)

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/take.wav"),
                encoding: .utf8
            ),
            "external"
        )
    }

    func testDestinationRemovedAfterPlanningRejectsInsteadOfRecreatingIt() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "source")
        try writeFile("Source/Audio/take.wav", in: destination, contents: "reviewed destination")

        let plan = try makeAudioPlan(source: source, destination: destination)
        let destinationFile = destination.appendingPathComponent("Source/Audio/take.wav")
        try FileManager.default.removeItem(at: destinationFile)

        let result = await execute(plan, conflictResolution: .replaceExisting)

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFile.path))
    }

    func testDestinationChangedDuringStagingRejectsBeforeCommit() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "source")

        let plan = try makeAudioPlan(source: source, destination: destination)
        let destinationFile = destination.appendingPathComponent("Source/Audio/take.wav")
        var injectedChange = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            publishProgress: { progress in
                guard progress.currentName != nil, !injectedChange else { return }
                try? FileManager.default.createDirectory(
                    at: destinationFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? "external".write(to: destinationFile, atomically: true, encoding: .utf8)
                injectedChange = true
            }
        )

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "external")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testLaterDestinationChangedAfterFirstCommitRejectsAndRollsBackBatch() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/a.wav", in: source, contents: "a")
        try writeFile("Audio/b.wav", in: source, contents: "b")

        let plan = try makeAudioPlan(source: source, destination: destination)
        let firstDestination = destination.appendingPathComponent("Source/Audio/a.wav")
        let laterDestination = destination.appendingPathComponent("Source/Audio/b.wav")
        var injectedChange = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            publishProgress: { progress in
                guard progress.copied == 1, !injectedChange else { return }
                try? "external".write(
                    to: laterDestination,
                    atomically: true,
                    encoding: .utf8
                )
                injectedChange = true
            }
        )

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.stalePlan)
        XCTAssertEqual(result.copied, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDestination.path))
        XCTAssertEqual(try String(contentsOf: laterDestination, encoding: .utf8), "external")
    }

    func testCancellationDoesNotDeleteConcurrentFileInsideCreatedDirectory() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/a.wav", in: source, contents: "a")
        try writeFile("Audio/b.wav", in: source, contents: "b")

        let plan = try makeAudioPlan(source: source, destination: destination)
        let externalFile = destination.appendingPathComponent("Source/Audio/external.txt")
        var shouldCancel = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            isCancelled: { shouldCancel },
            publishProgress: { progress in
                guard progress.copied == 1 else { return }
                try? "external".write(to: externalFile, atomically: true, encoding: .utf8)
                shouldCancel = true
            }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.rollbackFailed)
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), "external")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(result.recoveryPath))
        )
    }

    private func makeAudioPlan(
        source: URL,
        destination: URL
    ) throws -> MediaCopyBatchPlan {
        try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
    }

    private func execute(
        _ plan: MediaCopyBatchPlan,
        conflictResolution: MediaCopyConflictResolution
    ) async -> MediaCopyResult {
        await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: conflictResolution,
            publishProgress: { _ in }
        )
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

    private func writeFile(_ path: String, in root: URL, contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
