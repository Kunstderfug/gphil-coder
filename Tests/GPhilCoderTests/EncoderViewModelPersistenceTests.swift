import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class EncoderViewModelPersistenceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearPersistenceDefaultsForTests()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearPersistenceDefaultsForTests()
        try super.tearDownWithError()
    }

    func testEncodingSettingsReloadFromDefaultsPreservingHEVCScaleOverride() throws {
        let exportFolder = try makeTemporaryDirectory()

        var model: EncoderViewModel? = EncoderViewModel()
        model?.completionNotificationsEnabled = false
        model?.outputMode = .exportFolder
        model?.exportFolder = exportFolder
        model?.preserveSubfolders = false
        model?.overwriteExisting = true
        model?.confirmBeforeEncoding = false
        model?.outputFormat = .flac
        model?.mp3Mode = .cbr
        model?.vbrQuality = 4
        model?.cbrBitrateKbps = 256
        model?.abrBitrateKbps = 224
        model?.oggMode = .quality
        model?.oggQuality = 8
        model?.oggBitrateKbps = 192
        model?.opusRateMode = .constrained
        model?.opusBitrateKbps = 128
        model?.flacCompressionLevel = 5
        model?.splitOversizedMultichannel = false
        model?.parallelJobs = 2
        model?.ffmpegThreads = 1
        model?.deselectAllInputFormats()
        model?.setInputFormat(.flac, enabled: true)

        model?.encodingWorkflow = .video
        model?.deselectAllInputFormats()
        model?.setInputFormat(.mov, enabled: true)
        model?.videoOutputContainer = .mov
        model?.hevcPreset = .balanced4k
        model?.videoScaleMode = .source
        model?.customVideoBitrateKbps = 12_345
        model?.videoAudioMode = .aac320
        model?.videoHardwareDecodeMode = .off
        model = nil

        let restored = EncoderViewModel()

        XCTAssertEqual(restored.encodingWorkflow, .video)
        XCTAssertEqual(restored.outputMode, .exportFolder)
        XCTAssertEqual(restored.exportFolder?.standardizedFileURL, exportFolder.standardizedFileURL)
        XCTAssertEqual(restored.selectedInputExtensions, InputAudioFormat.flac.fileExtensions)
        XCTAssertEqual(restored.selectedVideoInputExtensions, InputVideoFormat.mov.fileExtensions)
        XCTAssertFalse(restored.preserveSubfolders)
        XCTAssertTrue(restored.overwriteExisting)
        XCTAssertFalse(restored.confirmBeforeEncoding)
        XCTAssertEqual(restored.outputFormat, .flac)
        XCTAssertEqual(restored.mp3Mode, .cbr)
        XCTAssertEqual(restored.vbrQuality, 4)
        XCTAssertEqual(restored.cbrBitrateKbps, 256)
        XCTAssertEqual(restored.abrBitrateKbps, 224)
        XCTAssertEqual(restored.oggMode, .quality)
        XCTAssertEqual(restored.oggQuality, 8)
        XCTAssertEqual(restored.oggBitrateKbps, 192)
        XCTAssertEqual(restored.opusRateMode, .constrained)
        XCTAssertEqual(restored.opusBitrateKbps, 128)
        XCTAssertEqual(restored.flacCompressionLevel, 5)
        XCTAssertFalse(restored.splitOversizedMultichannel)
        XCTAssertEqual(restored.parallelJobs, min(2, restored.processorLimit))
        XCTAssertEqual(restored.ffmpegThreads, min(1, restored.processorLimit))
        XCTAssertEqual(restored.videoOutputContainer, .mov)
        XCTAssertEqual(restored.hevcPreset, .balanced4k)
        XCTAssertEqual(restored.videoScaleMode, .source)
        XCTAssertEqual(restored.customVideoBitrateKbps, 12_345)
        XCTAssertEqual(restored.videoAudioMode, .aac320)
        XCTAssertEqual(restored.videoHardwareDecodeMode, .off)
    }

    func testFolderSyncSettingsAndPairsReloadFromDefaults() throws {
        let workspace = try makeTemporaryDirectory()
        let origin = try makeDirectory("Origin", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        var model: EncoderViewModel? = EncoderViewModel()
        model?.syncAutoSyncEnabled = false
        model?.syncOverwriteExisting = false
        model?.syncDeleteDestinationItems = false
        model?.syncDestinationLayout = .destinationRoot
        model?.syncFileFilter = .custom
        model?.syncCustomFileExtensions = "wav, flac"
        model?.syncDraftOriginRoot = origin
        model?.syncDraftDestinationRoot = destination
        model?.addSyncFolderPair()
        model = nil

        let restored = EncoderViewModel()

        XCTAssertFalse(restored.syncAutoSyncEnabled)
        XCTAssertFalse(restored.syncOverwriteExisting)
        XCTAssertFalse(restored.syncDeleteDestinationItems)
        XCTAssertEqual(restored.syncDestinationLayout, .destinationRoot)
        XCTAssertEqual(restored.syncFileFilter, .custom)
        XCTAssertEqual(restored.syncCustomFileExtensions, "wav, flac")
        XCTAssertEqual(restored.syncFolderPairs.count, 1)
        XCTAssertEqual(restored.syncFolderPairs[0].originURL.standardizedFileURL, origin.standardizedFileURL)
        XCTAssertEqual(
            restored.syncFolderPairs[0].destinationURL.standardizedFileURL,
            destination.standardizedFileURL
        )
        XCTAssertEqual(restored.syncFolderPairs[0].state, .idle)
    }

    func testMediaCopyAndRenameSettingsReloadFromDefaults() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("Source A", in: workspace)
        let secondSource = try makeDirectory("Source B", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        var model: EncoderViewModel? = EncoderViewModel()
        model?.completionNotificationsEnabled = false
        model?.mediaCopyFilter = .audio
        model?.deselectAllMediaCopyExtensions()
        model?.setMediaCopyExtension("wav", enabled: true)
        model?.fileManagementMode = .rename
        model?.mediaCopySourceRoots = [firstSource, secondSource]
        model?.mediaCopyDestinationRoot = destination
        model?.mediaFileNameFilterQuery = "dialogue"
        model?.mediaRenameOperation = .replaceText
        model?.mediaRenameFindText = "dialogue"
        model?.mediaRenameReplacementText = "voice"
        model?.mediaRenameIsCaseSensitive = true
        model?.mediaRenameSort = .modifiedDate
        model?.mediaRenameStartIndex = 42
        model?.mediaRenameIndexStep = 3
        model?.mediaRenameIndexPadding = 5
        model = nil

        let restored = EncoderViewModel()

        XCTAssertEqual(restored.fileManagementMode, .rename)
        XCTAssertEqual(
            restored.mediaCopySourceRoots.map(\.standardizedFileURL),
            [firstSource.standardizedFileURL, secondSource.standardizedFileURL]
        )
        XCTAssertEqual(restored.mediaCopyDestinationRoot?.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(restored.mediaCopyFilter, .audio)
        XCTAssertEqual(restored.mediaCopyAudioExtensions, ["wav"])
        XCTAssertEqual(restored.mediaFileNameFilterQuery, "dialogue")
        XCTAssertEqual(restored.mediaRenameOperation, .replaceText)
        XCTAssertEqual(restored.mediaRenameFindText, "dialogue")
        XCTAssertEqual(restored.mediaRenameReplacementText, "voice")
        XCTAssertTrue(restored.mediaRenameIsCaseSensitive)
        XCTAssertEqual(restored.mediaRenameSort, .modifiedDate)
        XCTAssertEqual(restored.mediaRenameStartIndex, 42)
        XCTAssertEqual(restored.mediaRenameIndexStep, 3)
        XCTAssertEqual(restored.mediaRenameIndexPadding, 5)
    }

    func testMediaRenameHistoryReloadsAndCapsUndoRedoStacks() throws {
        UserDefaults.standard.set(FileManagementMode.rename.rawValue, forKey: "fileManagementMode")
        let undoTransactions = (0..<25).map { makeRenameTransaction(index: $0) }
        let redoTransactions = (0..<23).map { makeRenameTransaction(index: 100 + $0) }
        let document = TestMediaRenameHistoryDocument(
            undoStack: undoTransactions,
            redoStack: redoTransactions
        )
        UserDefaults.standard.set(try JSONEncoder().encode(document), forKey: "mediaRenameHistory")

        let model = EncoderViewModel()

        XCTAssertEqual(model.mediaRenameUndoButtonTitle, "Undo (1)")
        XCTAssertEqual(model.mediaRenameRedoButtonTitle, "Redo (1)")
        XCTAssertEqual(model.mediaRenameUndoHelp, "Move 1 file back to their previous name")
        XCTAssertEqual(model.mediaRenameRedoHelp, "Reapply 1 previously undone rename")
    }

    func testSelectedPresetIDsNormalizeAfterPresetLoad() throws {
        let audioID = UUID()
        let videoID = UUID()
        let danglingID = UUID()
        let presets = [
            makeAudioPreset(id: audioID),
            makeVideoPreset(id: videoID)
        ]
        UserDefaults.standard.set(
            try JSONEncoder().encode(EncodingPresetDocument(presets: presets)),
            forKey: "encodingPresets"
        )
        UserDefaults.standard.set(videoID.uuidString, forKey: "selectedAudioEncodingPresetID")
        UserDefaults.standard.set(danglingID.uuidString, forKey: "selectedVideoEncodingPresetID")

        let model = EncoderViewModel()

        XCTAssertEqual(model.encodingPresets, presets)
        XCTAssertNil(model.selectedAudioEncodingPresetID)
        XCTAssertNil(model.selectedVideoEncodingPresetID)
        XCTAssertNil(UserDefaults.standard.string(forKey: "selectedAudioEncodingPresetID"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "selectedVideoEncodingPresetID"))
    }

    // MARK: - Fixtures

    private func makeAudioPreset(id: UUID) -> EncodingPreset {
        EncodingPreset(
            id: id,
            name: "Studio MP3",
            workflow: .audio,
            audio: AudioEncodingPresetSettings(
                outputFormat: .mp3,
                mp3Mode: .vbr,
                vbrQuality: 2,
                cbrBitrateKbps: 256,
                abrBitrateKbps: 192,
                oggMode: .quality,
                oggQuality: 6,
                oggBitrateKbps: 192,
                opusRateMode: .vbr,
                opusBitrateKbps: 128,
                flacCompressionLevel: 8,
                splitOversizedMultichannel: true
            )
        )
    }

    private func makeVideoPreset(id: UUID) -> EncodingPreset {
        EncodingPreset(
            id: id,
            name: "4K HEVC",
            workflow: .video,
            video: VideoEncodingPresetSettings(
                outputContainer: .mp4,
                hevcPreset: .balanced4k,
                customBitrateKbps: 22_000,
                audioMode: .copy
            )
        )
    }

    private func makeRenameTransaction(index: Int) -> MediaRenameHistoryTransaction {
        MediaRenameHistoryTransaction(
            actionTitle: "Rename \(index)",
            items: [
                MediaRenameHistoryItem(
                    originalPath: "/tmp/file-\(index).wav",
                    renamedPath: "/tmp/file-\(index)-renamed.wav",
                    originalName: "file-\(index).wav",
                    renamedName: "file-\(index)-renamed.wav",
                    fileSizeBytes: Int64(index + 1)
                )
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func clearPersistenceDefaultsForTests() {
        for key in Self.persistedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let persistedKeys = [
        "lastInputDirectoryPath",
        "outputMode",
        "exportFolderPath",
        "encodingWorkflow",
        "selectedInputExtensions",
        "selectedVideoInputExtensions",
        "preserveSubfolders",
        "overwriteExisting",
        "confirmBeforeEncoding",
        "outputFormat",
        "videoOutputContainer",
        "hevcPreset",
        "customVideoBitrateKbps",
        "videoScaleMode",
        "videoAudioMode",
        "videoHardwareDecodeMode",
        "mp3Mode",
        "vbrQuality",
        "cbrBitrateKbps",
        "abrBitrateKbps",
        "oggMode",
        "oggQuality",
        "oggBitrateKbps",
        "opusRateMode",
        "opusBitrateKbps",
        "flacCompressionLevel",
        "splitOversizedMultichannel",
        "parallelJobs",
        "ffmpegThreads",
        "ffmpegSourcePreference",
        "encodingPresets",
        "selectedAudioEncodingPresetID",
        "selectedVideoEncodingPresetID",
        "trashedSourceRecords",
        "restoreDeletedFolderPath",
        "restoreBackupRootPath",
        "restoreDestinationRootPath",
        "fileManagementMode",
        "mediaCopySourceRootPath",
        "mediaCopySourceRootPaths",
        "mediaCopyDestinationRootPath",
        "mediaCopyFilter",
        "mediaCopyAudioExtensions",
        "mediaCopyVideoExtensions",
        "mediaFileNameFilterQuery",
        "mediaRenameSettings",
        "mediaRenameHistory",
        "syncFolderPairs",
        "syncOverwriteExisting",
        "syncDeleteDestinationItems",
        "syncAutoSyncEnabled",
        "syncDestinationLayout",
        "syncFileFilter",
        "syncCustomFileExtensions",
        "completionNotificationsEnabled"
    ]
}

private struct TestMediaRenameHistoryDocument: Codable {
    var version = 1
    var undoStack: [MediaRenameHistoryTransaction]
    var redoStack: [MediaRenameHistoryTransaction]
}
