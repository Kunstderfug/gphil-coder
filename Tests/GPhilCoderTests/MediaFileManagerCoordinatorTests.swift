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
                contentsOf: destination.appendingPathComponent("Audio/Day 1/take.wav"),
                encoding: .utf8
            ),
            "source audio"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Video/Day 1/clip.mov").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Notes/readme.txt").path
            )
        )
        XCTAssertEqual(model.mediaCopyProgress?.skippedExisting, 0)
        XCTAssertEqual(model.statusMessage, "Copied 1 audio file to Destination.")
    }

    func testScanMediaCopyFilesReportsDestinationConflictsWithoutChangingFiles() async throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "new source")
        try writeFile("Audio/take.wav", in: destination, contents: "existing destination")

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
                contentsOf: destination.appendingPathComponent("Audio/take.wav"),
                encoding: .utf8
            ),
            "existing destination"
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
        XCTAssertEqual(model.mediaCopyQueueTotalCount, 2)

        model.runMediaCopyQueue()

        let copied = await waitUntil(timeout: 5) {
            !model.isMediaCopyBusy
                && model.mediaCopyProgress?.copied == 1
                && model.statusMessage.hasPrefix("Finished 2 file copy workflows: 2 copied.")
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
