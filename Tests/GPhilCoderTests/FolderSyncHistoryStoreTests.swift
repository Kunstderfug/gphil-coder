import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

final class FolderSyncHistoryStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRecordedRunSurvivesReloadWithCompleteMetadata() throws {
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let pairID = UUID()
        let recoveryID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let completedAt = startedAt.addingTimeInterval(3.5)
        let run = FolderSyncHistoryRun(
            id: UUID(),
            trigger: .automatic,
            startedAt: startedAt,
            completedAt: completedAt,
            pairs: [
                FolderSyncHistoryPairSnapshot(
                    id: pairID,
                    title: "Session Files",
                    originPath: "/Projects/Session",
                    destinationPath: "/Backups/Session"
                )
            ],
            settings: FolderSyncHistorySettingsSnapshot(
                destinationLayout: .originSubfolder,
                deleteDestinationItems: true,
                overwriteExisting: true,
                includedFileExtensions: ["flac", "wav"],
                automaticSyncEnabled: true
            ),
            items: [
                FolderSyncHistoryItem(
                    id: UUID(),
                    pairID: pairID,
                    operationID: "copyUpdated:mix.wav",
                    kind: .copyUpdated,
                    sourcePath: "/Projects/Session/mix.wav",
                    destinationPath: "/Backups/Session/mix.wav",
                    relativePath: "mix.wav",
                    fileSizeBytes: 4_096,
                    outcome: .successful,
                    outcomeMessage: "Copied",
                    retryEligible: false,
                    recovery: FolderSyncHistoryRecoveryReference(
                        recordID: recoveryID,
                        mechanism: .sameVolumeQuarantine
                    )
                )
            ]
        )
        let store = FolderSyncHistoryStore(fileURL: historyURL, retentionLimit: 10)

        try store.record(run)

        let reloaded = FolderSyncHistoryStore(fileURL: historyURL, retentionLimit: 10)
        XCTAssertEqual(reloaded.runs, [run])
        XCTAssertNil(reloaded.lastLoadFailure)
        XCTAssertEqual(reloaded.runs[0].counts.planned, 1)
        XCTAssertEqual(reloaded.runs[0].counts.successful, 1)
        XCTAssertEqual(reloaded.runs[0].items[0].recovery?.recordID, recoveryID)
    }

    func testHistoryIsBoundedNewestFirstAndRetainsNoChangeRuns() throws {
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("nested/history.json")
        let store = FolderSyncHistoryStore(fileURL: historyURL, retentionLimit: 3)
        let first = makeRun(trigger: .manual, completedAt: Date(timeIntervalSince1970: 1))
        let second = makeRun(trigger: .automatic, completedAt: Date(timeIntervalSince1970: 2))
        let third = makeRun(trigger: .retry, completedAt: Date(timeIntervalSince1970: 3))
        let noChange = makeRun(
            trigger: .manual,
            completedAt: Date(timeIntervalSince1970: 4),
            items: []
        )

        try store.record(first)
        try store.record(second)
        try store.record(third)
        try store.record(noChange)

        XCTAssertEqual(store.runs.map(\.id), [noChange.id, third.id, second.id])
        XCTAssertTrue(store.runs[0].isNoChange)
        XCTAssertEqual(store.runs[0].counts, FolderSyncHistoryCounts(
            planned: 0,
            successful: 0,
            skipped: 0,
            failed: 0,
            cancelled: 0
        ))
        XCTAssertEqual(VersionedBlob.version(from: try Data(contentsOf: historyURL)), 1)

        let reloaded = FolderSyncHistoryStore(fileURL: historyURL, retentionLimit: 3)
        XCTAssertEqual(reloaded.runs, store.runs)
    }

    func testCorruptReloadPreservesMemoryAndSourceBlobAndBlocksRecording() throws {
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let store = FolderSyncHistoryStore(fileURL: historyURL)
        let originalRun = makeRun()
        try store.record(originalRun)
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: historyURL, options: .atomic)

        let reloadResult = store.reload()

        guard case .failure(.corrupt) = reloadResult else {
            return XCTFail("Expected corrupt history, got \(reloadResult)")
        }
        XCTAssertEqual(store.runs, [originalRun])
        XCTAssertEqual(store.lastLoadFailure?.sourceData, corruptData)
        XCTAssertEqual(try Data(contentsOf: historyURL), corruptData)

        XCTAssertThrowsError(try store.record(makeRun())) { error in
            guard let storeError = error as? FolderSyncHistoryStoreError,
                case .unresolvedLoadFailure(.corrupt) = storeError
            else {
                return XCTFail("Expected unresolved corrupt load failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: historyURL), corruptData)
        XCTAssertEqual(store.runs, [originalRun])
    }

    func testFutureVersionReloadPreservesMemoryAndSourceBlob() throws {
        struct FutureEnvelope: Encodable {
            let version: Int
            let items: [FolderSyncHistoryRun]
        }

        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let store = FolderSyncHistoryStore(fileURL: historyURL)
        let originalRun = makeRun()
        try store.record(originalRun)
        let futureData = try JSONEncoder().encode(
            FutureEnvelope(version: 99, items: [makeRun()])
        )
        try futureData.write(to: historyURL, options: .atomic)

        let reloadResult = store.reload()

        guard case .failure(.versionMismatch(let found, let supported)) = reloadResult else {
            return XCTFail("Expected future-version history, got \(reloadResult)")
        }
        XCTAssertEqual(found, 99)
        XCTAssertEqual(supported, FolderSyncHistoryStore.currentVersion)
        XCTAssertEqual(store.runs, [originalRun])
        XCTAssertEqual(store.lastLoadFailure?.sourceData, futureData)
        XCTAssertEqual(try Data(contentsOf: historyURL), futureData)
    }

    func testClearRemovesOnlyHistoryMetadataAndLeavesRecoveryPayloadsUntouched() throws {
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("metadata/history.json")
        let recoveryPayloadURL = directory.appendingPathComponent(
            "recovery/run-1/original.wav",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: recoveryPayloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recoveryPayload = Data("recoverable audio".utf8)
        try recoveryPayload.write(to: recoveryPayloadURL)
        let store = FolderSyncHistoryStore(fileURL: historyURL)
        try store.record(makeRun())
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))

        try store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.lastLoadFailure)
        XCTAssertEqual(try Data(contentsOf: recoveryPayloadURL), recoveryPayload)
    }

    func testRetryCandidatesContainOnlyEligibleFailedAndCancelledItemsAfterReload() throws {
        let pairID = UUID()
        let successful = makeItem(
            pairID: pairID,
            outcome: .successful,
            retryEligible: true
        )
        let skipped = makeItem(
            pairID: pairID,
            outcome: .skipped,
            retryEligible: true
        )
        let ineligibleFailure = makeItem(
            pairID: pairID,
            outcome: .failed,
            retryEligible: false
        )
        let eligibleFailure = makeItem(
            pairID: pairID,
            outcome: .failed,
            retryEligible: true
        )
        let eligibleCancellation = makeItem(
            pairID: pairID,
            outcome: .cancelled,
            retryEligible: true
        )
        let run = makeRun(
            trigger: .retry,
            items: [
                successful,
                skipped,
                ineligibleFailure,
                eligibleFailure,
                eligibleCancellation
            ]
        )
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let store = FolderSyncHistoryStore(fileURL: historyURL)
        try store.record(run)
        let reloaded = FolderSyncHistoryStore(fileURL: historyURL)
        let persistedRun = try XCTUnwrap(reloaded.runs.first)

        let candidates = persistedRun.retryCandidates

        XCTAssertEqual(
            candidates.map(\.historyItemID),
            [eligibleFailure.id, eligibleCancellation.id]
        )
        XCTAssertEqual(candidates.map(\.runID), [persistedRun.id, persistedRun.id])
        XCTAssertEqual(candidates.map(\.pairID), [pairID, pairID])
        XCTAssertEqual(persistedRun.counts, FolderSyncHistoryCounts(
            planned: 5,
            successful: 1,
            skipped: 1,
            failed: 2,
            cancelled: 1
        ))
        XCTAssertFalse(candidates.contains(where: { $0.historyItemID == successful.id }))
    }

    func testPersistenceFailureDoesNotPublishAnUnstoredRunInMemory() throws {
        let directory = try makeTemporaryDirectory()
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let store = FolderSyncHistoryStore(
            fileURL: blockedParent.appendingPathComponent("history.json")
        )

        XCTAssertThrowsError(try store.record(makeRun()))

        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.lastLoadFailure)
        XCTAssertEqual(try Data(contentsOf: blockedParent), Data("blocker".utf8))
    }

    func testReloadAppliesRetentionLimitToAnExistingLargerDocument() throws {
        let directory = try makeTemporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let newest = makeRun(completedAt: Date(timeIntervalSince1970: 3))
        let middle = makeRun(completedAt: Date(timeIntervalSince1970: 2))
        let oldest = makeRun(completedAt: Date(timeIntervalSince1970: 1))
        try VersionedBlob.encode([newest, middle, oldest]).write(to: historyURL)
        let store = FolderSyncHistoryStore(fileURL: historyURL, retentionLimit: 2)

        let loadedRuns = try store.reload().get()

        XCTAssertEqual(loadedRuns, [newest, middle])
        XCTAssertEqual(store.runs, loadedRuns)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GPhilCoderFolderSyncHistoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeRun(
        id: UUID = UUID(),
        trigger: FolderSyncHistoryTrigger = .manual,
        completedAt: Date = Date(),
        items: [FolderSyncHistoryItem]? = nil
    ) -> FolderSyncHistoryRun {
        let pairID = UUID()
        return FolderSyncHistoryRun(
            id: id,
            trigger: trigger,
            startedAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt,
            pairs: [
                FolderSyncHistoryPairSnapshot(
                    id: pairID,
                    title: "Pair",
                    originPath: "/Origin",
                    destinationPath: "/Destination"
                )
            ],
            settings: FolderSyncHistorySettingsSnapshot(
                destinationLayout: .destinationRoot,
                deleteDestinationItems: false,
                overwriteExisting: true,
                includedFileExtensions: nil,
                automaticSyncEnabled: trigger == .automatic
            ),
            items: items ?? [
                makeItem(pairID: pairID, outcome: .successful)
            ]
        )
    }

    private func makeItem(
        id: UUID = UUID(),
        pairID: UUID = UUID(),
        outcome: FolderSyncHistoryItemOutcome,
        retryEligible: Bool = false
    ) -> FolderSyncHistoryItem {
        FolderSyncHistoryItem(
            id: id,
            pairID: pairID,
            operationID: "copyNew:file.wav",
            kind: .copyNew,
            sourcePath: "/Origin/file.wav",
            destinationPath: "/Destination/file.wav",
            relativePath: "file.wav",
            fileSizeBytes: 128,
            outcome: outcome,
            outcomeMessage: nil,
            retryEligible: retryEligible,
            recovery: nil
        )
    }
}
