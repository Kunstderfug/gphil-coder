import CryptoKit
import Darwin
import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

@MainActor
final class MediaCopyByteProgressTests: XCTestCase {
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

    func testLargeFileCopyPublishesStrictlyIncreasingIntraFileBytesBeforeNextFile() async throws {
        let firstName = "large-one.wav"
        let secondName = "large-two.wav"
        let fileSize: Int64 = 2_000_000
        let (plan, _) = try makeTwoLargeFilePlan(
            firstName: firstName,
            secondName: secondName,
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        let publications = await recordExecutePublications(plan: plan)

        let intraFile = intraFilePublications(
            in: publications,
            fileName: firstName,
            fileSize: fileSize
        )
        XCTAssertGreaterThanOrEqual(
            intraFile.count,
            3,
            "expected several intra-file publications while \(firstName) transfers; got \(publicationSummary(publications))"
        )
        XCTAssertTrue(
            zip(intraFile, intraFile.dropFirst()).allSatisfy { $0.copiedBytes < $1.copiedBytes },
            "intra-file copiedBytes must strictly increase: \(publicationSummary(intraFile))"
        )
        XCTAssertTrue(
            intraFile.allSatisfy { $0.currentName == firstName },
            "intra-file ticks must keep the transferring file name visible"
        )

        let lastIntraIndex = try XCTUnwrap(
            publications.lastIndex { snapshot in
                snapshot.currentName == firstName
                    && snapshot.copiedBytes > 0
                    && snapshot.copiedBytes < fileSize
            }
        )
        let nextFileIndex = try XCTUnwrap(
            publications.firstIndex { snapshot in
                snapshot.currentName == secondName || snapshot.copied >= 1
            }
        )
        XCTAssertLessThan(
            lastIntraIndex,
            nextFileIndex,
            "intra-file bytes for \(firstName) must land before the next file begins"
        )

        XCTAssertTrue(
            intraFile.allSatisfy { snapshot in
                snapshot.fractionCompleted == Double(snapshot.completed) / Double(snapshot.total)
            },
            "fractionCompleted must stay count-based during intra-file ticks"
        )
        XCTAssertTrue(
            publications.allSatisfy { $0.copiedBytes <= plan.totalSizeBytes },
            "intra-file reporting must never over-count the batch"
        )
        XCTAssertEqual(publications.last?.copiedBytes, plan.totalSizeBytes)
        assertPublicationCadenceIsBounded(intraFile)
    }

    func testCopiedBytesNeverRegressesAcrossTwoLargeFilePublicationHistory() async throws {
        let firstName = "large-one.wav"
        let secondName = "large-two.wav"
        let fileSize: Int64 = 2_000_000
        let (plan, _) = try makeTwoLargeFilePlan(
            firstName: firstName,
            secondName: secondName,
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        let publications = await recordExecutePublications(plan: plan)

        let firstFileIntra = intraFilePublications(
            in: publications,
            fileName: firstName,
            fileSize: fileSize
        )
        XCTAssertFalse(
            firstFileIntra.isEmpty,
            "file 1 must publish intra-file copiedBytes > 0; got \(publicationSummary(publications))"
        )
        let lastFirstFileCopiedBytes = try XCTUnwrap(firstFileIntra.last?.copiedBytes)
        XCTAssertGreaterThan(lastFirstFileCopiedBytes, 0)

        let firstFileLastIntraIndex = try XCTUnwrap(
            publications.lastIndex { snapshot in
                snapshot.currentName == firstName
                    && snapshot.copiedBytes > 0
                    && snapshot.copiedBytes < fileSize
            }
        )
        let laterPublications = publications.suffix(from: firstFileLastIntraIndex)
        XCTAssertTrue(
            laterPublications.contains { $0.currentName == secondName },
            "publication history must include file 2 after file 1 intra-file ticks"
        )
        XCTAssertTrue(
            laterPublications.allSatisfy { $0.copiedBytes >= lastFirstFileCopiedBytes },
            "file 2 publications must not drop below the last file-1 cumulative value \(lastFirstFileCopiedBytes): \(publicationSummary(Array(laterPublications)))"
        )
        XCTAssertTrue(
            zip(publications, publications.dropFirst()).allSatisfy {
                $0.copiedBytes <= $1.copiedBytes
            },
            "copiedBytes must never regress across the full two-file history: \(publicationSummary(publications))"
        )
        XCTAssertEqual(publications.last?.copiedBytes, plan.totalSizeBytes)
    }

    func testCompletedRunCopiedBytesEqualsPlannedTotalExactly() async throws {
        let fileSize: Int64 = 2_000_000
        let (plan, destination) = try makeTwoLargeFilePlan(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var publications: [MediaCopyProgress] = []
        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            publishProgress: { publications.append($0) }
        )

        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(publications.last?.copiedBytes, plan.totalSizeBytes)
        XCTAssertEqual(plan.totalSizeBytes, fileSize * 2)
        XCTAssertTrue(publications.allSatisfy { $0.copiedBytes <= plan.totalSizeBytes })
        XCTAssertFalse(
            publications.contains { snapshot in
                snapshot.currentName == "large-one.wav"
                    && snapshot.copiedBytes > fileSize
                    && snapshot.copied < 1
            },
            "first-file intra-file ticks must not include the second file"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/large-one.wav").path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testPackageAndXattrFileRemainByteIdenticalToCopyItemPath() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Session.app/Contents/Info.plist", in: source, contents: "metadata")
        try writeFile("Session.app/Contents/Resources/payload.dat", in: source, contents: "payload")
        let xattrURL = try writeBinaryFile(
            "xattr-large.wav",
            in: source,
            byteCount: 2_000_000,
            repeating: 0x5A
        )
        try setExtendedAttribute(
            named: "com.gphilcoder.test.byte-progress",
            value: Data("xattr-payload".utf8),
            at: xattrURL
        )

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .all
            )
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .skipExisting,
            publishProgress: { _ in }
        )

        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(result.failed, 0)

        let copiedPackage = destination.appendingPathComponent("Source/Session.app")
        let copiedXattr = destination.appendingPathComponent("Source/xattr-large.wav")
        try assertTreesByteIdentical(
            source.appendingPathComponent("Session.app"),
            copiedPackage
        )
        try assertFilesByteIdentical(xattrURL, copiedXattr)
        XCTAssertEqual(
            try extendedAttribute(named: "com.gphilcoder.test.byte-progress", at: copiedXattr),
            Data("xattr-payload".utf8)
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testSkippedExistingFilesContributeZeroBytesAndZeroSpeedSamples() async throws {
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

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var publications: [MediaCopyProgress] = []
        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .skipExisting,
            publishProgress: { publications.append($0) }
        )

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.skippedExisting, 1)
        XCTAssertEqual(publications.last?.copiedBytes, fileSize)
        XCTAssertEqual(publications.last?.skippedExisting, 1)
        XCTAssertFalse(
            publications.contains { snapshot in
                snapshot.currentName == "already-there.wav" && snapshot.copiedBytes > 0
                    && snapshot.copied == 0
            },
            "skipped-existing files must not contribute copied bytes or throughput samples"
        )
        XCTAssertTrue(
            publications
                .filter { $0.currentName == "already-there.wav" }
                .allSatisfy { $0.copiedBytes == 0 || $0.copied >= 1 },
            "skip snapshots must not treat destination-existing bytes as copied throughput"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Source/already-there.wav")),
            Data(repeating: 0x33, count: Int(fileSize))
        )
    }

    func testCancellingMidFileLeavesNoPartialDestinationOrTransactionRoot() async throws {
        let fileSize: Int64 = 2_000_000
        let (plan, destination) = try makeTwoLargeFilePlan(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()
        let firstDestination = destination.appendingPathComponent("Source/large-one.wav")
        let secondDestination = destination.appendingPathComponent("Source/large-two.wav")
        var shouldCancel = false

        let result = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            isCancelled: { shouldCancel },
            publishProgress: { progress in
                if progress.currentName == "large-one.wav",
                    progress.copiedBytes > 0,
                    progress.copiedBytes < fileSize
                {
                    shouldCancel = true
                }
            }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDestination.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".gphilcoder-copy-") }
        )
    }

    func testIntraFileTicksDoNotInvalidateWorkflowStateAndCadenceIsBounded() async throws {
        let fileSize: Int64 = 2_000_000
        let (plan, _) = try makeTwoLargeFilePlan(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()
        let reviewedPlan = plan
        var publications: [MediaCopyProgress] = []

        let result = await MediaCopyTransactionExecutor.execute(
            reviewedPlan,
            conflictResolution: .replaceExisting,
            publishProgress: { publications.append($0) }
        )

        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(reviewedPlan.candidates.map(\.id), plan.candidates.map(\.id))
        XCTAssertEqual(reviewedPlan.totalSizeBytes, plan.totalSizeBytes)
        XCTAssertEqual(reviewedPlan.sourcePlans.count, plan.sourcePlans.count)
        let intraFile = intraFilePublications(
            in: publications,
            fileName: "large-one.wav",
            fileSize: fileSize
        )
        XCTAssertGreaterThanOrEqual(intraFile.count, 3)
        assertPublicationCadenceIsBounded(intraFile)
        XCTAssertTrue(
            intraFile.allSatisfy { snapshot in
                snapshot.completed == snapshot.copied + snapshot.skippedExisting + snapshot.failed
            }
        )
    }

    func testCopyNowCoordinatorBindsIntraFileSnapshotsWithoutMutatingQueuePlanOrScan() async throws {
        let fileSize: Int64 = 2_000_000
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile("large-one.wav", in: source, byteCount: fileSize, repeating: 0x41)
        try writeBinaryFile("large-two.wav", in: source, byteCount: fileSize, repeating: 0x42)

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaCopyConflictResolutionHandler = { _ in .replaceExisting }
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        model.scanMediaCopyFiles()
        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2 }
        XCTAssertTrue(scanned)
        let scannedPlan = try XCTUnwrap(model.mediaCopyPlan)
        let scannedIDs = scannedPlan.candidates.map(\.id)
        let queueBefore = model.mediaCopyQueue

        var boundSnapshots: [MediaCopyProgress] = []
        var lastBound: MediaCopyProgress?
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if let progress = model.mediaCopyProgress,
                lastBound.map({
                    $0.copiedBytes != progress.copiedBytes
                        || $0.currentName != progress.currentName
                        || $0.updatedAt != progress.updatedAt
                }) ?? true
            {
                boundSnapshots.append(progress)
                lastBound = progress
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)

        let intraFile = intraFilePublications(
            in: boundSnapshots,
            fileName: "large-one.wav",
            fileSize: fileSize
        )
        XCTAssertGreaterThanOrEqual(
            intraFile.count,
            3,
            "Copy Now must bind intra-file snapshots on mediaCopyProgress; got \(publicationSummary(boundSnapshots))"
        )
        XCTAssertEqual(model.mediaCopyProgress?.copiedBytes, scannedPlan.totalSizeBytes)
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), queueBefore.map(\.id))
        XCTAssertEqual(model.mediaCopyPlan?.candidates.map(\.id), scannedIDs)
        assertPublicationCadenceIsBounded(intraFile)
    }

    private func makeTwoLargeFilePlan(
        firstName: String,
        secondName: String,
        fileSize: Int64
    ) throws -> (MediaCopyBatchPlan, URL) {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile(firstName, in: source, byteCount: fileSize, repeating: 0xA1)
        try writeBinaryFile(secondName, in: source, byteCount: fileSize, repeating: 0xA2)
        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                filter: .audio
            )
        )
        return (plan, destination)
    }

    private func recordExecutePublications(
        plan: MediaCopyBatchPlan
    ) async -> [MediaCopyProgress] {
        var publications: [MediaCopyProgress] = []
        _ = await MediaCopyTransactionExecutor.execute(
            plan,
            conflictResolution: .replaceExisting,
            publishProgress: { publications.append($0) }
        )
        return publications
    }

    private func intraFilePublications(
        in publications: [MediaCopyProgress],
        fileName: String,
        fileSize: Int64
    ) -> [MediaCopyProgress] {
        publications.filter { snapshot in
            snapshot.currentName == fileName
                && snapshot.copiedBytes > 0
                && snapshot.copiedBytes < fileSize
        }
    }

    private func publicationSummary(_ publications: [MediaCopyProgress]) -> String {
        publications.map { "\($0.currentName ?? "-"):\($0.copiedBytes)" }.joined(separator: ", ")
    }

    private func assertPublicationCadenceIsBounded(_ publications: [MediaCopyProgress]) {
        let maximumPublicationsPerSecond = 8.0
        guard publications.count >= 2 else { return }
        let elapsed = publications.last!.updatedAt.timeIntervalSince(publications.first!.updatedAt)
        let rate = Double(publications.count - 1) / max(elapsed, 0.001)
        XCTAssertLessThanOrEqual(
            rate,
            maximumPublicationsPerSecond,
            "publication cadence must stay bounded; rate=\(rate) count=\(publications.count) elapsed=\(elapsed)"
        )
    }

    private func assertTreesByteIdentical(_ source: URL, _ destination: URL) throws {
        let sourceFiles = try regularFileURLs(under: source)
        let destinationFiles = try regularFileURLs(under: destination)
        XCTAssertEqual(
            Set(sourceFiles.map { relativePath(of: $0, under: source) }),
            Set(destinationFiles.map { relativePath(of: $0, under: destination) })
        )
        for sourceFile in sourceFiles {
            let destinationFile = destination.appendingPathComponent(
                relativePath(of: sourceFile, under: source)
            )
            try assertFilesByteIdentical(sourceFile, destinationFile)
        }
    }

    private func assertFilesByteIdentical(_ source: URL, _ destination: URL) throws {
        let sourceData = try Data(contentsOf: source)
        let destinationData = try Data(contentsOf: destination)
        XCTAssertEqual(sourceData, destinationData)
        XCTAssertEqual(SHA256.hash(data: sourceData), SHA256.hash(data: destinationData))
    }

    private func regularFileURLs(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        )
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func setExtendedAttribute(named name: String, value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { buffer in
            setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> Data {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var buffer = Data(count: length)
        let readLength = buffer.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard readLength == length else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return buffer
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
    private func writeFile(_ path: String, in root: URL, contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
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
