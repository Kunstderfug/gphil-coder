import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

final class RecoverableFolderSyncCopyFailureTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCopyNewFinalJournalFailureRemovesCreatedFileAndClearsOneShotIntent() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("new take".utf8).write(to: source)
        let store = FailAppliedStateOnceRecoveryStore()
        let service = try RecoverableFolderSyncMutationService(store: store)
        let runID = UUID()

        let result = await service.apply(
            makeCopyNewOperation(
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("take.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let memoryRecords = await service.recoveryRecords(runID: runID)
        XCTAssertTrue(memoryRecords.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)

        let reloadedService = try RecoverableFolderSyncMutationService(store: store)
        let reloadedRecords = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertTrue(reloadedRecords.isEmpty)
    }

    func testCopyNewPersistentFinalJournalFailureKeepsResolvableIntentAcrossRelaunch() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("new take".utf8).write(to: source)
        let store = FailAfterAppliedAttemptRecoveryStore()
        let service = try RecoverableFolderSyncMutationService(store: store)
        let runID = UUID()

        let result = await service.apply(
            makeCopyNewOperation(
                source: source,
                destination: target,
                destinationRoot: destination
            ),
            runID: runID,
            overwriteExisting: true
        )

        XCTAssertEqual(result.operationResult, .failed("take.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let memoryRecords = await service.recoveryRecords(runID: runID)
        let durableRecords = try store.load()
        XCTAssertEqual(memoryRecords, durableRecords)
        XCTAssertEqual(memoryRecords.count, 1)
        XCTAssertEqual(memoryRecords.first?.state, .intent)
        XCTAssertNotNil(memoryRecords.first?.appliedFingerprint)

        let reloadedService = try RecoverableFolderSyncMutationService(store: store)
        let reloadedRecords = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertEqual(reloadedRecords, durableRecords)

        store.recoverWrites()
        let report = await reloadedService.rollback(runID: runID)

        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 0)
        let recordsAfterRollback = await reloadedService.recoveryRecords(runID: runID)
        XCTAssertTrue(recordsAfterRollback.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCopyNewFinalJournalFailureDoesNotRemoveChangedDestination() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let source = origin.appendingPathComponent("take.txt")
        let target = destination.appendingPathComponent("take.txt")
        try Data("new take".utf8).write(to: source)
        let store = FailAppliedStateOnceRecoveryStore {
            try Data("changed outside sync".utf8).write(to: target)
        }
        let service = try RecoverableFolderSyncMutationService(store: store)
        let runID = UUID()

        let result = await service.apply(
            makeCopyNewOperation(
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
            "changed outside sync"
        )
        let records = await service.recoveryRecords(runID: runID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .recoveryFailed)
        XCTAssertNotNil(records.first?.appliedFingerprint)
        XCTAssertEqual(records, try store.load())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GPhilCoder-CopyFailureTests-\(UUID().uuidString)",
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

    private func makeCopyNewOperation(
        source: URL,
        destination: URL,
        destinationRoot: URL
    ) -> FolderSyncBatchOperation {
        let operation = FolderSyncOperation(
            kind: .copyNew,
            sourceURL: source,
            destinationURL: destination,
            relativePath: destination.lastPathComponent
        )
        let plan = FolderSyncPlan(
            originRoot: source.deletingLastPathComponent(),
            destinationRoot: destinationRoot,
            operations: [operation],
            operationCount: 1,
            copyCount: 1,
            updatedCount: 0,
            createdDirectoryCount: 0,
            deletedFileCount: 0,
            deletedDirectoryCount: 0,
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

private final class FailAppliedStateOnceRecoveryStore: FolderSyncRecoveryJournalStore {
    struct WriteFailure: Error {}

    private var records: [FolderSyncRecoveryRecord] = []
    private var hasFailedAppliedState = false
    private let onAppliedFailure: () throws -> Void

    init(onAppliedFailure: @escaping () throws -> Void = {}) {
        self.onAppliedFailure = onAppliedFailure
    }

    func load() throws -> [FolderSyncRecoveryRecord] { records }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        if !hasFailedAppliedState, records.contains(where: { $0.state == .applied }) {
            hasFailedAppliedState = true
            try onAppliedFailure()
            throw WriteFailure()
        }
        self.records = records
    }
}

private final class FailAfterAppliedAttemptRecoveryStore: FolderSyncRecoveryJournalStore {
    struct WriteFailure: Error {}

    private var records: [FolderSyncRecoveryRecord] = []
    private var writesAreUnavailable = false

    func load() throws -> [FolderSyncRecoveryRecord] { records }

    func save(_ records: [FolderSyncRecoveryRecord]) throws {
        if records.contains(where: { $0.state == .applied }) {
            writesAreUnavailable = true
        }
        guard !writesAreUnavailable else { throw WriteFailure() }
        self.records = records
    }

    func recoverWrites() {
        writesAreUnavailable = false
    }
}
