import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class MediaCopyFileCountProgressTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearMediaFileManagerDefaultsForTests()
        MediaCopyTransactionExecutor.resetByteProgressTestHooks()
    }

    override func tearDownWithError() throws {
        MediaCopyTransactionExecutor.resetByteProgressTestHooks()
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearMediaFileManagerDefaultsForTests()
        try super.tearDownWithError()
    }

    func testCopyNowAdvancesDisplayCountsAfterStagingBeforeInstall() async throws {
        let fileSize: Int64 = 2_000_000
        let (model, scannedPlan, queueBefore) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        let scannedIDs = scannedPlan.candidates.map(\.id)
        let queueIDs = queueBefore.map(\.id)
        let scannedBytes = scannedPlan.totalSizeBytes
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var sawIntraFileCountsStayZero = false
        var sawDisplayCountsAfterFirstFileBeforeInstall = false
        var sawLastFileStagedBeforeInstall = false
        var sawInstallCommittedCopied = false
        var displayCountDecreased = false
        var surfacesDiverged: String?
        var identityDrift: String?
        var peakDisplayCopied = 0
        var lastDisplay: FileCopyDisplaySnapshot?

        model.copyFilteredMediaFiles()
        let finished = await waitUntil(timeout: 15) {
            guard let progress = model.mediaCopyProgress else { return false }
            let display = self.fileCopyDisplaySnapshot(from: model)

            if progress.currentName == "large-one.wav",
                progress.copiedBytes > 0,
                progress.copiedBytes < fileSize
            {
                if display.copied == 0, display.completed == 0, progress.copied == 0 {
                    sawIntraFileCountsStayZero = true
                } else if display.copied != 0 || display.completed != 0 {
                    surfacesDiverged =
                        surfacesDiverged
                        ?? "intra-file tick incremented display counts: \(display)"
                }
            }

            if progress.copiedBytes >= fileSize, progress.copied == 0 {
                if display.copied > 0, display.completed > 0 {
                    sawDisplayCountsAfterFirstFileBeforeInstall = true
                }
            }

            if progress.copiedBytes >= scannedBytes, progress.copied == 0 {
                if display.copied == 2, display.completed == 2 {
                    sawLastFileStagedBeforeInstall = true
                }
            }

            if progress.copied >= 1 {
                sawInstallCommittedCopied = true
            }

            if display.isLiveProgressFooter {
                if let previous = lastDisplay,
                    display.copied < previous.copied
                        || display.completed < previous.completed
                {
                    displayCountDecreased = true
                }
                if display.copied > peakDisplayCopied {
                    peakDisplayCopied = display.copied
                }
                if display.surfacesDiverge {
                    surfacesDiverged =
                        surfacesDiverged
                        ?? "header, copied label, and footer diverged: \(display)"
                }
                lastDisplay = display
            }
            if model.mediaCopyQueue.map(\.id) != queueIDs {
                identityDrift = identityDrift ?? "queue IDs changed during a count tick"
            } else if model.mediaCopyPlan?.candidates.map(\.id) != scannedIDs {
                identityDrift = identityDrift ?? "plan candidate IDs changed during a count tick"
            } else if model.mediaCopyPlan?.totalSizeBytes != scannedBytes {
                identityDrift = identityDrift ?? "scan-derived plan identity changed during a count tick"
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }

        XCTAssertTrue(finished)
        XCTAssertTrue(
            sawIntraFileCountsStayZero,
            "while the first file is mid-transfer, display copied and completed must stay 0"
        )
        XCTAssertTrue(
            sawDisplayCountsAfterFirstFileBeforeInstall,
            "header N of total, N copied, and footer Copied N must leave 0 after the first file finishes staging and before MediaCopyResult.copied increments"
        )
        XCTAssertTrue(
            sawLastFileStagedBeforeInstall,
            "after the last file finishes staging, display counts must reach the planned total before install increments progress.copied"
        )
        XCTAssertTrue(
            sawInstallCommittedCopied,
            "progress.copied must still become 1 only at the first destination commit"
        )
        XCTAssertFalse(displayCountDecreased, "install publications must not drop displayed counts")
        XCTAssertNil(surfacesDiverged, surfacesDiverged ?? "")
        XCTAssertNil(identityDrift, identityDrift ?? "")
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), queueIDs)
        XCTAssertEqual(model.mediaCopyPlan?.candidates.map(\.id), scannedIDs)
        XCTAssertEqual(model.mediaCopyPlan?.totalSizeBytes, scannedBytes)
        XCTAssertEqual(model.mediaCopyCountCompletionText, "2 of 2")
        XCTAssertEqual(try XCTUnwrap(lastDisplay).copied, 2)
        XCTAssertEqual(try XCTUnwrap(lastDisplay).copiedLabel, "2 copied")
        XCTAssertEqual(try XCTUnwrap(lastDisplay).skipped, 0)
        XCTAssertEqual(try XCTUnwrap(lastDisplay).failed, 0)
        XCTAssertEqual(try XCTUnwrap(lastDisplay).completed, 2)
        XCTAssertEqual(model.mediaCopyProgress?.copied, 2)
        XCTAssertEqual(model.mediaCopyProgress?.copiedBytes, scannedBytes)
        XCTAssertEqual(model.mediaCopyByteFractionCompleted, 1.0)
        XCTAssertGreaterThan(peakDisplayCopied, 0)
        XCTAssertFalse(model.mediaCopySpeedSummaryText.isEmpty)
    }

    func testCopyNowSkipAdvancesCompletedWithoutCountingSkipBytesOrInstallCopied() async throws {
        let fileSize: Int64 = 2_000_000
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile("copy-me.wav", in: source, byteCount: fileSize, repeating: 0x11)
        try writeBinaryFile("already-there.wav", in: source, byteCount: fileSize, repeating: 0x22)
        try writeBinaryFile(
            "Source/already-there.wav",
            in: destination,
            byteCount: fileSize,
            repeating: 0x33
        )

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaCopyConflictResolutionHandler = { _ in .skipExisting }
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        model.scanMediaCopyFiles()
        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2 }
        XCTAssertTrue(scanned)

        var sawSkipBeforeInstall = false
        var sawStagedCopyBeforeInstall = false
        var skipContributedBytes = false
        var surfacesDiverged: String?

        model.copyFilteredMediaFiles()
        let finished = await waitUntil(timeout: 15) {
            guard let progress = model.mediaCopyProgress else { return false }
            let display = self.fileCopyDisplaySnapshot(from: model)
            if display.isLiveProgressFooter, display.surfacesDiverge {
                surfacesDiverged =
                    surfacesDiverged
                    ?? "header, copied label, and footer diverged: \(display)"
            }
            if progress.currentName == "already-there.wav",
                progress.copiedBytes > 0,
                progress.copied == 0
            {
                skipContributedBytes = true
            }
            if display.skipped == 1, display.copied == 0, progress.copied == 0 {
                sawSkipBeforeInstall = true
            }
            if display.copied == 1, display.skipped == 1, progress.copied == 0 {
                sawStagedCopyBeforeInstall = true
            }
            return !model.isMediaCopyBusy
                && model.mediaCopyProgress?.copied == 1
                && model.mediaCopyProgress?.skippedExisting == 1
        }

        XCTAssertTrue(finished)
        XCTAssertTrue(sawSkipBeforeInstall, "a skip during staging must advance the shared snapshot")
        XCTAssertTrue(
            sawStagedCopyBeforeInstall,
            "the successfully staged file must increment Copied N before install commits MediaCopyResult.copied"
        )
        XCTAssertFalse(skipContributedBytes)
        XCTAssertNil(surfacesDiverged, surfacesDiverged ?? "")
        XCTAssertEqual(model.mediaCopyCountCompletionText, "2 of 2")
        XCTAssertEqual(model.mediaCopyProgress?.copied, 1)
        XCTAssertEqual(model.mediaCopyProgress?.copiedBytes, fileSize)
        XCTAssertEqual(model.mediaCopyByteFractionCompleted, 1.0)
    }

    private struct FileCopyDisplaySnapshot: Equatable, CustomStringConvertible {
        var completed: Int
        var total: Int
        var copied: Int
        var skipped: Int
        var failed: Int
        var header: String
        var copiedLabel: String
        var footer: String

        var isLiveProgressFooter: Bool {
            footer.contains(", skipped ") && footer.contains(", failed ")
        }

        var surfacesDiverge: Bool {
            completed != copied + skipped + failed
                || header != "\(completed) of \(total)"
                || copiedLabel != "\(copied) copied"
                || !footer.hasPrefix(
                    "Copied \(copied), skipped \(skipped), failed \(failed) of \(total)"
                )
        }

        var description: String {
            "header=\(header) copiedLabel=\(copiedLabel) footer=\(footer)"
        }
    }

    /// Reads the File Copy count surfaces the UI already binds: header
    /// `mediaCopyCountCompletionText` ("N of total"), the copied label owner
    /// (same snapshot N as footer "Copied N"), and the coordinator footer.
    /// `progress.copied` stays the install-committed count and is not this owner.
    private func fileCopyDisplaySnapshot(from model: EncoderViewModel) -> FileCopyDisplaySnapshot {
        let header = model.mediaCopyCountCompletionText
        let footer = model.statusMessage
        let headerCounts = parseCountCompletion(header)
        let footerCounts = parseCopiedFooter(footer)
        let copied = footerCounts?.copied ?? 0
        return FileCopyDisplaySnapshot(
            completed: headerCounts?.completed ?? 0,
            total: headerCounts?.total ?? model.mediaCopyProgress?.total ?? 0,
            copied: copied,
            skipped: footerCounts?.skipped ?? model.mediaCopyProgress?.skippedExisting ?? 0,
            failed: footerCounts?.failed ?? model.mediaCopyProgress?.failed ?? 0,
            header: header,
            copiedLabel: "\(copied) copied",
            footer: footer
        )
    }

    private func parseCountCompletion(_ text: String) -> (completed: Int, total: Int)? {
        let parts = text.split(separator: " ")
        guard parts.count == 3, parts[1] == "of",
            let completed = Int(parts[0]),
            let total = Int(parts[2])
        else {
            return nil
        }
        return (completed, total)
    }

    private func parseCopiedFooter(
        _ text: String
    ) -> (copied: Int, skipped: Int, failed: Int, total: Int)? {
        let pattern =
            #"Copied (\d+), skipped (\d+), failed (\d+) of (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let copiedRange = Range(match.range(at: 1), in: text),
            let skippedRange = Range(match.range(at: 2), in: text),
            let failedRange = Range(match.range(at: 3), in: text),
            let totalRange = Range(match.range(at: 4), in: text),
            let copied = Int(text[copiedRange]),
            let skipped = Int(text[skippedRange]),
            let failed = Int(text[failedRange]),
            let total = Int(text[totalRange])
        else {
            return nil
        }
        return (copied, skipped, failed, total)
    }

    private func makeScannedCopyNowModel(
        firstName: String,
        secondName: String,
        fileSize: Int64
    ) async throws -> (EncoderViewModel, MediaCopyBatchPlan, [MediaCopyWorkflow]) {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile(firstName, in: source, byteCount: fileSize, repeating: 0x41)
        try writeBinaryFile(secondName, in: source, byteCount: fileSize, repeating: 0x42)

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaCopyConflictResolutionHandler = { _ in .replaceExisting }

        model.scanMediaCopyFiles()
        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2 }
        XCTAssertTrue(scanned)
        let scannedPlan = try XCTUnwrap(model.mediaCopyPlan)
        return (model, scannedPlan, model.mediaCopyQueue)
    }

    private func makeMediaFileManagerModel() -> EncoderViewModel {
        let queueStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GPhilCoderTests-QueueStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryDirectories.append(queueStorageRoot)
        let model = EncoderViewModel(mediaCopyQueueStorageRoot: queueStorageRoot)
        model.completionNotificationsEnabled = false
        model.fileManagementMode = .copy
        model.mediaCopyFilter = .audio
        model.mediaFileNameFilterQuery = ""
        model.selectAllMediaCopyExtensions()
        return model
    }

    private func clearMediaFileManagerDefaultsForTests() {
        clearViewModelDefaultsForTests()
        let keys = [
            "completionNotificationsEnabled",
            "mediaCopySourceRootPath",
            "mediaCopySourceRootPaths",
            "mediaCopyDestinationRootPath",
            "mediaCopyDestinationLayout",
            "mediaCopyFilter",
            "mediaCopyAudioExtensions",
            "mediaCopyVideoExtensions",
            "mediaFileNameFilterQuery",
            "mediaRenameSettings",
            "mediaRenameHistory"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
    private func writeBinaryFile(
        _ path: String,
        in root: URL,
        byteCount: Int64,
        repeating byte: UInt8
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: byte, count: Int(byteCount)).write(to: url)
        return url
    }
}
