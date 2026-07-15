import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class RestoreCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testBuildPlanPublishesRecordsAndSummary() async throws {
        let workspace = try makeTemporaryDirectory()
        let deleted = try makeDirectory("Deleted", in: workspace)
        let backup = try makeDirectory("Backup", in: workspace)
        let restore = try makeDirectory("Restore", in: workspace)
        try writeFile("Album/Song.flac", in: deleted, contents: "audio")
        try writeFile("Album/Song.flac", in: backup, contents: "audio")

        let state = RestoreCoordinatorState()
        let coordinator = makeCoordinator(state: state)

        coordinator.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameOnly,
                hashMode: .auto,
                includeHidden: false
            )
        )

        let completed = await waitUntil { !state.isPlanning && !state.records.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(state.records.map(\.status), [.matched])
        XCTAssertEqual(state.scanSummary?.deletedFileCount, 1)
        XCTAssertNil(state.progress)
        XCTAssertFalse(state.stoppedWithPartialResults)
        XCTAssertEqual(
            state.statusMessage,
            "Restore plan built: 0 restored, 1 backup matches, 0 target exists, 0 ambiguous, 0 missing."
        )
    }

    func testApplyPlanCopiesMatchedBackupFilesAndReportsResult() async throws {
        let workspace = try makeTemporaryDirectory()
        let deleted = try makeDirectory("Deleted", in: workspace)
        let backup = try makeDirectory("Backup", in: workspace)
        let restore = try makeDirectory("Restore", in: workspace)
        try writeFile("Album/Song.flac", in: deleted, contents: "deleted")
        try writeFile("Album/Song.flac", in: backup, contents: "backup")
        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameOnly,
                hashMode: .auto,
                includeHidden: false
            )
        )

        let state = RestoreCoordinatorState()
        let coordinator = makeCoordinator(state: state)

        coordinator.apply(records: plan.records, copySource: .backup, overwrite: false)

        let completed = await waitUntil { !state.isRestoring && !state.restoredURLs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            try String(contentsOf: restore.appendingPathComponent("Album/Song.flac"), encoding: .utf8),
            "backup"
        )
        XCTAssertEqual(state.restoredURLs.map(\.lastPathComponent), ["Song.flac"])
        XCTAssertEqual(state.statusMessage, "Restored 1 file.")
    }

    func testCopyUnresolvedItemsCopiesIntoDestinationWithCollisionSuffix() async throws {
        let workspace = try makeTemporaryDirectory()
        let deleted = try makeDirectory("Deleted", in: workspace)
        let destination = try makeDirectory("Restore/GPhil MediaFlow Unresolved Files", in: workspace)
        let source = try writeFile("Song.flac", in: deleted, contents: "source")
        try writeFile("Song.flac", in: destination, contents: "existing")
        let item = RestoreUnresolvedFile(
            id: source.path,
            name: "Song.flac",
            matchName: nil,
            deletedPath: source.path,
            size: 6
        )

        let state = RestoreCoordinatorState()
        let coordinator = makeCoordinator(state: state)

        coordinator.copyUnresolvedItems([item], to: destination)

        let completed = await waitUntil { !state.isRestoring && !state.restoredURLs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(state.restoredURLs.map(\.lastPathComponent), ["Song 2.flac"])
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Song 2.flac"), encoding: .utf8),
            "source"
        )
        XCTAssertEqual(
            state.statusMessage,
            "Copied 1 unresolved file to GPhil MediaFlow Unresolved Files."
        )
    }

    func testExportUnresolvedItemsWritesJSONAndReportsResult() throws {
        let workspace = try makeTemporaryDirectory()
        let deleted = try makeDirectory("Deleted", in: workspace)
        let source = try writeFile("Song.flac", in: deleted, contents: "source")
        let item = RestoreUnresolvedFile(
            id: source.path,
            name: "Song.flac",
            matchName: "Song.flac",
            deletedPath: source.path,
            size: 6
        )
        let state = RestoreCoordinatorState()
        let coordinator = makeCoordinator(state: state)
        let destination = workspace.appendingPathComponent("unresolved-export")

        coordinator.exportUnresolvedItems(
            RestoreUnresolvedExportRequest(
                items: [item],
                isPartialSearchSnapshot: true,
                deletedFolderPath: deleted.path,
                backupRootPath: "/Backups",
                restoreRootPath: "/Restored",
                matchMode: "Filename",
                hashMode: "Auto",
                progressPhase: "Scanning",
                progressDetail: "Checking files",
                deletedCount: 2,
                restoredCount: 1
            ),
            to: destination
        )

        let exportURL = destination.appendingPathExtension("json")
        let data = try Data(contentsOf: exportURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["isPartialSearchSnapshot"] as? Bool, true)
        XCTAssertEqual(object["deletedCount"] as? Int, 2)
        XCTAssertEqual(object["restoredCount"] as? Int, 1)
        XCTAssertEqual(object["unresolvedListCount"] as? Int, 1)
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["name"] as? String, "Song.flac")
        XCTAssertEqual(state.statusMessage, "Exported 1 unresolved file to unresolved-export.json.")
    }

    private func makeCoordinator(state: RestoreCoordinatorState) -> RestoreCoordinator {
        RestoreCoordinator(
            setRecords: { state.records = $0 },
            setLiveCounts: { state.liveCounts = $0 },
            setLiveUnresolvedItems: { state.liveUnresolvedItems = $0 },
            setScanSummary: { state.scanSummary = $0 },
            setProgress: { state.progress = $0 },
            setPlanning: { state.isPlanning = $0 },
            setRestoring: { state.isRestoring = $0 },
            setStoppedWithPartialResults: { state.stoppedWithPartialResults = $0 },
            setStatusMessage: { state.statusMessage = $0 },
            appendRestoredFileURLs: { state.restoredURLs.append(contentsOf: $0) }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderRestoreCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
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

private final class RestoreCoordinatorState {
    var records: [RestorePlanRecord] = []
    var liveCounts: RestorePlanStatusCounts?
    var liveUnresolvedItems: [RestoreUnresolvedFile] = []
    var scanSummary: RestorePlanScanSummary?
    var progress: RestorePlanProgress?
    var isPlanning = false
    var isRestoring = false
    var stoppedWithPartialResults = false
    var statusMessage = ""
    var restoredURLs: [URL] = []
}
