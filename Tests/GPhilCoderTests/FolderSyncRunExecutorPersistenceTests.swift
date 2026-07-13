import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class FolderSyncRunExecutorPersistenceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testHistoryFailureAfterMutationLeavesDurableReviewStateAndStopsScheduling() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try Data("first".utf8).write(to: origin.appendingPathComponent("a.txt"))
        try Data("second".utf8).write(to: origin.appendingPathComponent("b.txt"))

        let historyURL = workspace.appendingPathComponent("history.json")
        var historyWriteCount = 0
        let historyStore = FolderSyncHistoryStore(
            fileURL: historyURL,
            dataWriter: { data, url in
                historyWriteCount += 1
                guard historyWriteCount != 3 else { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        let recoveryURL = workspace.appendingPathComponent("recovery.json")
        let mutationService = try RecoverableFolderSyncMutationService(
            store: FolderSyncVersionedJSONRecoveryStore(fileURL: recoveryURL),
            trash: UnavailableTrashBoundary()
        )
        let executor = FolderSyncRunExecutor(
            historyStore: historyStore,
            mutationService: mutationService
        )
        let pairID = UUID()
        let pair = SyncFolderPair(
            id: pairID,
            originPath: origin.path,
            destinationPath: destination.path
        )
        let pairPlan = FolderSyncPairPlan(
            pairID: pairID,
            pairTitle: pair.displayTitle,
            plan: try FolderSyncPlanner.buildPlan(
                originRoot: origin,
                destinationRoot: destination
            )
        )
        let plan = FolderSyncBatchPlan(pairPlans: [pairPlan])
        let configuration = FolderSyncRunConfiguration(
            pairs: [pair],
            destinationLayout: .destinationRoot,
            deleteDestinationItems: false,
            overwriteExisting: true,
            includedFileExtensions: nil,
            autoSyncEnabled: false,
            watchOrigins: [],
            previewLimit: 300
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                trigger: .manual,
                configuration: configuration,
                onUpdate: { _ in }
            )
            XCTFail("Expected the injected history write failure")
        } catch is InjectedWriteFailure {
            // Expected after the first mutation, before a second item is scheduled.
        }

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8),
            "first"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("b.txt").path
            )
        )

        let reloadedHistory = FolderSyncHistoryStore(fileURL: historyURL)
        let durableRun = try XCTUnwrap(reloadedHistory.runs.first)
        let firstItem = try XCTUnwrap(
            durableRun.items.first { $0.relativePath == "a.txt" }
        )
        let unscheduledItem = try XCTUnwrap(
            durableRun.items.first { $0.relativePath == "b.txt" }
        )
        XCTAssertTrue(firstItem.requiresOutcomeReview)
        XCTAssertFalse(firstItem.retryEligible)
        XCTAssertEqual(durableRun.unresolvedOutcomeCount, 1)
        XCTAssertEqual(durableRun.resultTitle, "Outcome Review Required")
        XCTAssertEqual(firstItem.historyOutcomeTitle, "Review Required")
        XCTAssertTrue(
            firstItem.accessibilitySummary.localizedCaseInsensitiveContains("review required")
        )
        XCTAssertEqual(unscheduledItem.outcome, .cancelled)
        XCTAssertFalse(unscheduledItem.requiresOutcomeReview)
        XCTAssertTrue(unscheduledItem.retryEligible)
        XCTAssertEqual(durableRun.counts.cancelled, 1)

        let reloadedMutationService = try RecoverableFolderSyncMutationService(
            store: FolderSyncVersionedJSONRecoveryStore(fileURL: recoveryURL),
            trash: UnavailableTrashBoundary()
        )
        let durableRecovery = await reloadedMutationService.recoveryRecords(
            runID: durableRun.id
        )
        XCTAssertEqual(durableRecovery.count, 1)
        XCTAssertEqual(durableRecovery.first?.state, .applied)
        XCTAssertEqual(durableRecovery.first?.targetPath, firstItem.destinationPath)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GPhilCoderRunExecutorPersistenceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct InjectedWriteFailure: Error {}

private struct UnavailableTrashBoundary: FolderSyncTrashBoundary {
    func moveToTrash(_ url: URL) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
