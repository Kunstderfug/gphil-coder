import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

@MainActor
final class MediaFileManagerCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearMediaFileManagerDefaultsForTests()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearMediaFileManagerDefaultsForTests()
        try super.tearDownWithError()
    }

    func testScanMediaCopyFilesFiltersBySelectedExtensionAndName() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/camera_001.wav", in: source, contents: "camera one")
        try writeFile("Audio/camera_002.flac", in: source, contents: "camera two")
        try writeFile("Audio/roomtone.wav", in: source, contents: "tone")
        try writeFile("Video/camera_003.mov", in: source, contents: "video")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "CAMERA_"

        model.scanMediaCopyFiles()

        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.mediaCopyConflictCount, 0)
        XCTAssertEqual(model.mediaCopyPreviewItems.map(\.relativePath), ["Audio/camera_001.wav"])
        XCTAssertEqual(model.activeMediaMatchedCount, 1)
        XCTAssertEqual(model.activeMediaActionName, "copy")
    }

    func testScanMediaCopyFilesIncludesEverySelectedSourceUsingSourceFolderLayout() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [firstSource, secondSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.scanMediaCopyFiles()

        let scanned = await waitUntil {
            !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2
        }
        XCTAssertTrue(scanned)
        XCTAssertEqual(
            Set(model.mediaCopyPreviewItems.map { $0.sourceURL.standardizedFileURL.path }),
            Set([
                firstSource.appendingPathComponent("Audio/first.wav").standardizedFileURL.path,
                secondSource.appendingPathComponent("Audio/second.wav").standardizedFileURL.path,
            ])
        )
        XCTAssertEqual(
            Set(model.mediaCopyPreviewItems.map { $0.destinationURL.standardizedFileURL.path }),
            Set([
                destination.appendingPathComponent("FirstSource/Audio/first.wav").standardizedFileURL.path,
                destination.appendingPathComponent("SecondSource/Audio/second.wav").standardizedFileURL.path,
            ])
        )
    }

    func testCopyFilteredMediaFilesCopiesNestedAudioWithoutShowingConflictPrompt() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/Day 1/take.wav", in: source, contents: "source audio")
        try writeFile("Video/Day 1/clip.mov", in: source, contents: "source video")
        try writeFile("Notes/readme.txt", in: source, contents: "notes")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.copyFilteredMediaFiles()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.mediaCopyProgress?.completed == 1
                && model.mediaCopyProgress?.copied == 1
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/Day 1/take.wav"),
                encoding: .utf8
            ),
            "source audio"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/Video/Day 1/clip.mov").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Source/Notes/readme.txt").path
            )
        )
        XCTAssertEqual(model.mediaCopyProgress?.skippedExisting, 0)
        XCTAssertEqual(model.statusMessage, "Copied 1 audio file to Destination.")
    }

    func testCopyNowUsesExplicitMergeContentsLayoutAcrossAllSources() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [firstSource, secondSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyDestinationLayout = .mergeContents
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.copyFilteredMediaFiles()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Audio/first.wav")),
            "first"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Audio/second.wav")),
            "second"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("FirstSource/Audio/first.wav").path
            )
        )
    }

    func testCopyPreflightValidatesLayoutResolvedDestination() throws {
        let workspace = try makeTemporaryDirectory()
        let selectedDestination = try makeDirectory("Parent", in: workspace)
        let source = try makeDirectory("Parent/Session", in: workspace)
        try writeFile("take.wav", in: source, contents: "audio")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = selectedDestination
        model.mediaCopyDestinationLayout = .sourceFolders
        var validatedDestination: URL?
        model.mediaCopyFolderValidationHandler = { _, destination in
            validatedDestination = destination
            return false
        }

        model.copyFilteredMediaFiles()

        XCTAssertEqual(
            validatedDestination?.standardizedFileURL.path,
            source.standardizedFileURL.path
        )
        XCTAssertFalse(model.isMediaCopyBusy)
    }

    func testScanMediaCopyFilesReportsDestinationConflictsWithoutChangingFiles() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "new source")
        try writeFile("Source/Audio/take.wav", in: destination, contents: "existing destination")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.scanMediaCopyFiles()

        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.mediaCopyConflictCount, 1)
        XCTAssertEqual(model.mediaCopyPreviewItems.first?.relativePath, "Audio/take.wav")
        XCTAssertEqual(model.mediaCopyPreviewItems.first?.hasDestinationConflict, true)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/take.wav"),
                encoding: .utf8
            ),
            "existing destination"
        )
    }

    func testCopyNowConflictDenialLeavesDestinationUnchanged() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "new source")
        try writeFile("Source/Audio/take.wav", in: destination, contents: "existing destination")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.mediaCopyConflictResolutionHandler = { _ in nil }

        model.copyFilteredMediaFiles()

        let denied = await waitUntil {
            !model.isMediaCopyBusy && model.statusMessage == "Media copy cancelled."
        }
        XCTAssertTrue(denied)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Source/Audio/take.wav"),
                encoding: .utf8
            ),
            "existing destination"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix(".gphilcoder-copy-") },
            []
        )
    }

    func testRunMediaCopyQueueCopiesEachWorkflowUnderSourceFolder() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")
        try writeFile("Video/clip.mov", in: secondSource, contents: "video")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [firstSource, secondSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.addCurrentMediaCopyWorkflowToQueue()
        XCTAssertEqual(model.mediaCopyQueueTotalCount, 1)

        model.runMediaCopyQueue()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.mediaCopyProgress?.copied == 2
                && model.statusMessage.hasPrefix("Finished 1 file copy workflow: 2 copied.")
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("FirstSource/Audio/first.wav"),
                encoding: .utf8
            ),
            "first"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("SecondSource/Audio/second.wav"),
                encoding: .utf8
            ),
            "second"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("SecondSource/Video/clip.mov").path
            )
        )
        XCTAssertNil(model.currentMediaCopyWorkflowID)
    }

    func testQueuedMergeWorkflowsSharingNewParentDoNotRejectOwnedChangesAsStale() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")
        let workflows = [firstSource, secondSource].map { source in
            MediaCopyWorkflow(
                sourceRoots: [source],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .audio
            )
        }
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: workflows)

        model.runMediaCopyQueue()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.statusMessage.hasPrefix("Finished 2 file copy workflows: 2 copied.")
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Audio/first.wav")),
            "first"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Audio/second.wav")),
            "second"
        )
    }

    func testQueuedWorkflowPromptIncludesCrossWorkflowDestinationCollisions() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: firstSource, contents: "first")
        try writeFile("Audio/take.wav", in: secondSource, contents: "second")
        let workflows = [firstSource, secondSource].map { source in
            MediaCopyWorkflow(
                sourceRoots: [source],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .audio
            )
        }
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: workflows)
        var reviewedConflictCount = 0
        model.mediaCopyConflictResolutionHandler = { plans in
            reviewedConflictCount = plans.reduce(0) { $0 + $1.conflictCount }
            return .skipExisting
        }

        model.runMediaCopyQueue()

        let finished = await waitUntil(timeout: 5) { !model.isMediaCopyBusy }
        XCTAssertTrue(finished)
        XCTAssertEqual(reviewedConflictCount, 2)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Audio/take.wav")),
            "first"
        )
    }

    func testLaterStaleQueuedWorkflowRollsBackEarlierCompletedCopies() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let firstDestination = try makeDirectory("FirstDestination", in: workspace)
        let secondDestination = try makeDirectory("SecondDestination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")
        let workflows = [
            MediaCopyWorkflow(
                sourceRoots: [firstSource],
                destinationRoot: firstDestination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
            MediaCopyWorkflow(
                sourceRoots: [secondSource],
                destinationRoot: secondDestination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
        ]
        let staleDestination = secondDestination.appendingPathComponent("Audio/second.wav")
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: workflows)
        model.mediaCopyConflictResolutionHandler = { _ in
            try? FileManager.default.createDirectory(
                at: staleDestination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "external".write(
                to: staleDestination,
                atomically: true,
                encoding: .utf8
            )
            return .skipExisting
        }

        model.runMediaCopyQueue()

        let stopped = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.statusMessage.contains("Completed queue changes were rolled back")
        }
        XCTAssertTrue(stopped)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: firstDestination.appendingPathComponent("Audio/first.wav").path
            )
        )
        XCTAssertEqual(try String(contentsOf: staleDestination), "external")
        XCTAssertTrue(model.statusMessage.contains("stale workflow made no destination changes"))
    }

    func testQueuedNestedDestinationRebasesOwnedRootEvidence() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let nestedDestination = try makeDirectory("Nested", in: destination)
        try writeFile("first.wav", in: firstSource, contents: "first")
        try writeFile("Nested/second.wav", in: secondSource, contents: "second")
        let workflows = [
            MediaCopyWorkflow(
                sourceRoots: [firstSource],
                destinationRoot: nestedDestination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
            MediaCopyWorkflow(
                sourceRoots: [secondSource],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
        ]
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: workflows)

        model.runMediaCopyQueue()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.statusMessage.hasPrefix("Finished 2 file copy workflows: 2 copied.")
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(contentsOf: nestedDestination.appendingPathComponent("first.wav")),
            "first"
        )
        XCTAssertEqual(
            try String(contentsOf: nestedDestination.appendingPathComponent("second.wav")),
            "second"
        )
    }

    func testCancellingLaterQueuedWorkflowRollsBackEarlierWorkflow() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let firstDestination = try makeDirectory("FirstDestination", in: workspace)
        let secondDestination = try makeDirectory("SecondDestination", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        for index in 0..<250 {
            try writeFile(
                "Audio/Batch/file-\(index).wav",
                in: secondSource,
                contents: "second-\(index)"
            )
        }
        let workflows = [
            MediaCopyWorkflow(
                sourceRoots: [firstSource],
                destinationRoot: firstDestination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
            MediaCopyWorkflow(
                sourceRoots: [secondSource],
                destinationRoot: secondDestination,
                destinationLayout: .mergeContents,
                filter: .audio
            ),
        ]
        let firstCopiedURL = firstDestination.appendingPathComponent("Audio/first.wav")
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: workflows)

        model.runMediaCopyQueue()

        let secondStarted = await waitUntil(timeout: 10) {
            model.currentMediaCopyWorkflowID == workflows[1].id
                && FileManager.default.fileExists(atPath: firstCopiedURL.path)
        }
        XCTAssertTrue(secondStarted)
        model.cancelMediaCopy()

        let rolledBack = await waitUntil(timeout: 10) {
            !FileManager.default.fileExists(atPath: firstCopiedURL.path)
        }
        XCTAssertTrue(rolledBack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCopiedURL.path))
    }

    func testQueueFinalizationRemainsBusyButCannotBeCancelled() {
        let model = makeMediaFileManagerModel()
        model.isMediaCopyFinalizing = true

        XCTAssertTrue(model.isMediaCopyBusy)
        XCTAssertFalse(model.canCancelMediaCopy)

        model.cancelMediaCopy()

        XCTAssertTrue(model.isMediaCopyFinalizing)
        XCTAssertTrue(model.isMediaCopyBusy)
    }

    func testQueuedCopyPreservesCompleteSourceSetAndMatchesImmediateLayout() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let immediateDestination = try makeDirectory("Immediate", in: workspace)
        let queuedDestination = try makeDirectory("Queued", in: workspace)
        try writeFile("Audio/first.wav", in: firstSource, contents: "first")
        try writeFile("Audio/second.wav", in: secondSource, contents: "second")

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [firstSource, secondSource]
        model.mediaCopyDestinationRoot = immediateDestination
        model.mediaCopyDestinationLayout = .mergeContents
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)

        model.copyFilteredMediaFiles()
        let immediateCopied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(immediateCopied)

        model.mediaCopyDestinationRoot = queuedDestination
        model.addCurrentMediaCopyWorkflowToQueue()

        XCTAssertEqual(model.mediaCopyQueueTotalCount, 1)
        XCTAssertEqual(model.mediaCopyQueue.first?.sourceRoots, [firstSource, secondSource])
        XCTAssertEqual(model.mediaCopyQueue.first?.destinationLayout, .mergeContents)

        model.runMediaCopyQueue()
        let queuedCopied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.statusMessage.hasPrefix("Finished 1 file copy workflow: 2 copied.")
        }
        XCTAssertTrue(queuedCopied)

        for relativePath in ["Audio/first.wav", "Audio/second.wav"] {
            XCTAssertEqual(
                try Data(contentsOf: immediateDestination.appendingPathComponent(relativePath)),
                try Data(contentsOf: queuedDestination.appendingPathComponent(relativePath))
            )
        }
    }

    func testRejectedCopyJobDataDoesNotReplaceCurrentQueue() throws {
        let existingWorkflow = MediaCopyWorkflow(
            sourceRoots: [URL(fileURLWithPath: "/Volumes/Current", isDirectory: true)],
            destinationRoot: URL(fileURLWithPath: "/Volumes/Target", isDirectory: true),
            destinationLayout: .mergeContents,
            filter: .audio
        )
        let model = makeMediaFileManagerModel()
        model.replaceMediaCopyQueue(with: [existingWorkflow])
        let futureData = """
            {
              "version": \(MediaCopyJobDocument.currentVersion + 1),
              "savedAt": "2026-07-13T00:00:00Z",
              "workflows": []
            }
            """.data(using: .utf8)!

        XCTAssertThrowsError(try model.loadMediaCopyJobData(futureData))
        XCTAssertEqual(model.mediaCopyQueue, [existingWorkflow])

        XCTAssertThrowsError(try model.loadMediaCopyJobData(Data("not json".utf8)))
        XCTAssertEqual(model.mediaCopyQueue, [existingWorkflow])
    }

    func testDeletePreviewUsesInventoryAcrossMultipleSourcesAndFileNameFilter() async throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        try writeFile("Audio/camera_a.wav", in: firstSource, contents: "first")
        try writeFile("Audio/camera_b.flac", in: secondSource, contents: "second")
        try writeFile("Audio/roomtone.wav", in: secondSource, contents: "tone")
        try writeFile("Video/camera_c.mov", in: secondSource, contents: "video")

        let model = makeMediaFileManagerModel()
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "camera"
        model.fileManagementMode = .delete
        model.mediaCopySourceRoots = [firstSource, secondSource]

        model.refreshMediaDeletePreview()

        let scanned = await waitUntil { !model.isMediaCopyBusy && model.activeMediaMatchedCount == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.mediaDeletePreviewItems.map(\.relativePath), ["Audio/camera_a.wav"])
        XCTAssertEqual(model.activeMediaPlanTitle, "Filtered Delete Plan")
        XCTAssertTrue(model.canDeleteFilteredMediaFiles)
    }

    func testRenamePreviewRebuildsFromInventoryWhenSettingsChange() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        try writeFile("Audio/dialogue.wav", in: source, contents: "dialogue")
        try writeFile("Audio/music.wav", in: source, contents: "music")
        try writeFile("Video/dialogue.mov", in: source, contents: "video")

        let model = makeMediaFileManagerModel()
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "dialogue"
        model.mediaRenameOperation = .replaceText
        model.mediaRenameFindText = "dialogue"
        model.mediaRenameReplacementText = "voice"
        model.fileManagementMode = .rename
        model.mediaCopySourceRoots = [source]

        model.refreshMediaRenamePreview()

        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaRenameReadyCount == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.mediaRenamePreviewItems.map(\.newName), ["voice.wav"])
        XCTAssertEqual(model.mediaRenameBlockedCount, 0)
        XCTAssertEqual(model.mediaRenameUnchangedCount, 0)
        XCTAssertTrue(model.canRenameFilteredMediaFiles)

        model.mediaRenameReplacementText = "line"

        let rebuilt = await waitUntil { model.mediaRenamePreviewItems.map(\.newName) == ["line.wav"] }
        XCTAssertTrue(rebuilt)
        XCTAssertFalse(model.isMediaRenamePreviewStale)
    }

    func testRenamePreviewMarksConflictsAndPreventsApply() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        try writeFile("Audio/dialogue.wav", in: source, contents: "dialogue")
        try writeFile("Audio/voice.wav", in: source, contents: "voice")

        let model = makeMediaFileManagerModel()
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "dialogue"
        model.mediaRenameOperation = .replaceText
        model.mediaRenameFindText = "dialogue"
        model.mediaRenameReplacementText = "voice"
        model.fileManagementMode = .rename
        model.mediaCopySourceRoots = [source]

        model.refreshMediaRenamePreview()

        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaRenameBlockedCount == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(model.mediaRenameReadyCount, 0)
        XCTAssertEqual(model.mediaRenamePreviewItems.map(\.state), [.conflict])
        XCTAssertEqual(model.mediaRenamePreviewItems.map(\.newName), ["voice.wav"])
        XCTAssertFalse(model.canRenameFilteredMediaFiles)
    }

    private func makeMediaFileManagerModel() -> EncoderViewModel {
        let model = EncoderViewModel()
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
}
