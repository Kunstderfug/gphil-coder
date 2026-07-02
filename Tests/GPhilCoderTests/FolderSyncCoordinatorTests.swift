import Foundation
import XCTest
@testable import GPhilCoder

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

        let model = makeFolderSyncModel()
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

    func testRerunIsNoOpUntilOriginChanges() async throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let sourceFile = try writeFile("track.txt", in: origin, contents: "first")

        let model = makeFolderSyncModel()
        addPair(origin: origin, destination: destination, to: model)

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

        let model = makeFolderSyncModel()
        addPair(origin: enabledOrigin, destination: enabledDestination, to: model)
        addPair(origin: disabledOrigin, destination: disabledDestination, to: model)
        guard let disabledPair = model.syncFolderPairs.last else {
            XCTFail("Expected disabled pair to be added.")
            return
        }
        model.setSyncFolderPair(disabledPair, enabled: false)

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

        let model = makeFolderSyncModel()
        model.syncFileFilter = .custom
        model.syncCustomFileExtensions = "wav"
        addPair(origin: origin, destination: destination, to: model)

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

        let model = makeFolderSyncModel()
        model.syncOverwriteExisting = false
        addPair(origin: origin, destination: destination, to: model)

        model.syncFoldersNow()

        let synced = await waitUntil(timeout: 5) { !model.isFolderSyncBusy }
        XCTAssertTrue(synced)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("track.txt"), encoding: .utf8),
            "old"
        )
        XCTAssertEqual(model.statusMessage, "Folder sync finished, 0 copied, 0 deleted, 1 skipped.")
    }

    private func makeFolderSyncModel() -> EncoderViewModel {
        let model = EncoderViewModel()
        model.completionNotificationsEnabled = false
        model.syncAutoSyncEnabled = false
        model.syncDestinationLayout = .destinationRoot
        model.syncFileFilter = .all
        model.syncOverwriteExisting = true
        model.syncDeleteDestinationItems = true
        return model
    }

    private func addPair(origin: URL, destination: URL, to model: EncoderViewModel) {
        model.syncDraftOriginRoot = origin
        model.syncDraftDestinationRoot = destination
        model.addSyncFolderPair()
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
