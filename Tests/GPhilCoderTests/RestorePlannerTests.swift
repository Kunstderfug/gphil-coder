import Foundation
import XCTest
@testable import GPhilCoderCore

final class RestorePlannerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testBuildPlanMatchesBackupFileByFilenameAndSize() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: deleted, contents: "audio-bytes")
        try writeFile("Project/Song.flac", in: backup, contents: "audio-bytes")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .matched)
        XCTAssertEqual(plan.records[0].relativePath, "Project/Song.flac")
        XCTAssertEqual(plan.scanSummary.deletedFileCount, 1)
        XCTAssertEqual(plan.scanSummary.backupCandidateCount, 1)
    }

    func testBuildPlanMarksAlreadyRestoredWhenRestoreRootContainsMatch() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: deleted, contents: "audio-bytes")
        try writeFile("Song.flac", in: restore, contents: "audio-bytes")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .alreadyRestored)
        XCTAssertEqual(plan.records[0].backupURL, nil)
        XCTAssertEqual(plan.scanSummary.backupCandidateCount, 0)
    }

    func testBuildPlanReportsMissingWhenNoBackupCandidate() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Lost.flac", in: deleted, contents: "gone")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .missing)
        XCTAssertEqual(plan.records[0].backupURL, nil)
    }

    func testBuildPlanFlagsConflictWhenRestoreTargetExistsWithDifferentSize() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Album/Song.flac", in: deleted, contents: "twelve-bytes")
        try writeFile("Album/Song.flac", in: backup, contents: "twelve-bytes")
        // Different content + size at the same restore path → conflict.
        try writeFile("Album/Song.flac", in: restore, contents: "different-bytes-here")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        // filenameAndSize match key is name+size; the restore-root file has a
        // different size so it does not count as alreadyRestored. The backup
        // match lands at a restore path that already exists → matchedConflict.
        let matchedRecords = plan.records.filter { $0.status == .matchedConflict }
        XCTAssertEqual(matchedRecords.count, 1)
        XCTAssertEqual(matchedRecords[0].restoreURL?.path,
                       restore.appendingPathComponent("Album/Song.flac").path)
    }

    func testFilenameOnlyModeMatchesAcrossDifferingSizes() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: deleted, contents: "short")
        try writeFile("Archive/Song.flac", in: backup, contents: "much-longer-content-here")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameOnly,
                hashMode: .never,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .matched)
    }

    func testTrashTimestampSuffixIsStrippedFromDeletedFilenames() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        // macOS Trash copies are named like "Song.flac 16-37-33-880.flac".
        try writeFile("Song.flac 16-37-33-880.flac", in: deleted, contents: "audio-bytes")
        try writeFile("Album/Song.flac", in: backup, contents: "audio-bytes")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .matched)
        XCTAssertEqual(plan.records[0].displayName, "Song.flac 16-37-33-880.flac")
        XCTAssertEqual(plan.records[0].relativePath, "Album/Song.flac")
    }

    func testAmbiguousWhenMultipleBackupPathsMatch() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: deleted, contents: "audio-bytes")
        try writeFile("A/Song.flac", in: backup, contents: "audio-bytes")
        try writeFile("B/Song.flac", in: backup, contents: "audio-bytes")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .ambiguous)
        XCTAssertEqual(plan.records[0].candidates.count, 2)
    }

    func testHashAlwaysDisambiguatesByContent() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: deleted, contents: "real")
        // Same name + size but different bytes → hash mismatch → missing.
        try writeFile("A/Song.flac", in: backup, contents: "fake")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .always,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.records[0].status, .missing)
        XCTAssertNotNil(plan.records[0].sha256)
    }

    func testApplyCopiesMatchedRecordsFromBackup() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        // Identical content so filenameAndSize matches; deleted path differs
        // from the restore-relative path so it is not alreadyRestored.
        try writeFile("Song.flac", in: deleted, contents: "backup-copy")
        try writeFile("Album/Song.flac", in: backup, contents: "backup-copy")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records[0].status, .matched)
        let result = RestorePlanner.apply(records: plan.records, copySource: .backup, overwrite: false)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.failed, 0)
        let restored = try String(
            contentsOf: restore.appendingPathComponent("Album/Song.flac"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "backup-copy")
    }

    func testApplySkipsExistingRestoreTargetWithoutOverwrite() throws {
        let deleted = try makeTemporaryDirectory()
        let backup = try makeTemporaryDirectory()
        let restore = try makeTemporaryDirectory()
        // Deleted + backup match by filenameAndSize; the restore-root file at
        // the same path has a different size so it is not alreadyRestored —
        // the backup match lands on an existing target → matchedConflict.
        try writeFile("Song.flac", in: deleted, contents: "twelve-bytes")
        try writeFile("Album/Song.flac", in: backup, contents: "twelve-bytes")
        try writeFile("Album/Song.flac", in: restore, contents: "different-bytes-here")

        let plan = try RestorePlanner.buildPlan(
            options: RestorePlanOptions(
                deletedFolder: deleted,
                backupRoot: backup,
                restoreRoot: restore,
                matchMode: .filenameAndSize,
                hashMode: .auto,
                includeHidden: false
            )
        )

        XCTAssertEqual(plan.records[0].status, .matchedConflict)
        let result = RestorePlanner.apply(records: plan.records, copySource: .backup, overwrite: false)
        XCTAssertEqual(result.copied, 0)
        // matchedConflict record, target exists, overwrite off → skipped.
        XCTAssertEqual(result.skipped, 1)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderRestoreTests-\(UUID().uuidString)", isDirectory: true)
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
