import AppKit
import Foundation
import GPhilCoderCore
import UniformTypeIdentifiers

@MainActor
final class EncoderViewModel: ObservableObject {
    private enum DefaultsKey {
        static let lastInputDirectoryPath = "lastInputDirectoryPath"
        static let outputMode = "outputMode"
        static let exportFolderPath = "exportFolderPath"
        static let encodingWorkflow = "encodingWorkflow"
        static let selectedInputExtensions = "selectedInputExtensions"
        static let selectedVideoInputExtensions = "selectedVideoInputExtensions"
        static let preserveSubfolders = "preserveSubfolders"
        static let overwriteExisting = "overwriteExisting"
        static let outputFormat = "outputFormat"
        static let videoOutputContainer = "videoOutputContainer"
        static let hevcPreset = "hevcPreset"
        static let customVideoBitrateKbps = "customVideoBitrateKbps"
        static let videoScaleMode = "videoScaleMode"
        static let videoAudioMode = "videoAudioMode"
        static let videoHardwareDecodeMode = "videoHardwareDecodeMode"
        static let mp3Mode = "mp3Mode"
        static let vbrQuality = "vbrQuality"
        static let cbrBitrateKbps = "cbrBitrateKbps"
        static let abrBitrateKbps = "abrBitrateKbps"
        static let oggMode = "oggMode"
        static let oggQuality = "oggQuality"
        static let oggBitrateKbps = "oggBitrateKbps"
        static let opusRateMode = "opusRateMode"
        static let opusBitrateKbps = "opusBitrateKbps"
        static let flacCompressionLevel = "flacCompressionLevel"
        static let splitOversizedMultichannel = "splitOversizedMultichannel"
        static let parallelJobs = "parallelJobs"
        static let ffmpegThreads = "ffmpegThreads"
        static let ffmpegSourcePreference = "ffmpegSourcePreference"
        static let encodingPresets = "encodingPresets"
        static let selectedAudioEncodingPresetID = "selectedAudioEncodingPresetID"
        static let selectedVideoEncodingPresetID = "selectedVideoEncodingPresetID"
        static let trashedSourceRecords = "trashedSourceRecords"
        static let restoreDeletedFolderPath = "restoreDeletedFolderPath"
        static let restoreBackupRootPath = "restoreBackupRootPath"
        static let restoreDestinationRootPath = "restoreDestinationRootPath"
        static let fileManagementMode = "fileManagementMode"
        static let mediaCopySourceRootPath = "mediaCopySourceRootPath"
        static let mediaCopySourceRootPaths = "mediaCopySourceRootPaths"
        static let mediaCopyDestinationRootPath = "mediaCopyDestinationRootPath"
        static let mediaCopyFilter = "mediaCopyFilter"
        static let mediaCopyAudioExtensions = "mediaCopyAudioExtensions"
        static let mediaCopyVideoExtensions = "mediaCopyVideoExtensions"
        static let mediaFileNameFilterQuery = "mediaFileNameFilterQuery"
        static let mediaRenameSettings = "mediaRenameSettings"
        static let mediaRenameHistory = "mediaRenameHistory"
    }

    private static let mediaRenameHistoryLimit = 20
    private static let mediaPreviewLimit = 300
    private static let mediaFileNameFilterDebounceNanoseconds: UInt64 = 400_000_000

    private enum QueueFile {
        static let fileExtension = "gphilcoderqueue"
        static let legacyFileExtension = "gphilcodecqueue"

        static var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .json
        }

        static var legacyContentType: UTType {
            UTType(filenameExtension: legacyFileExtension) ?? .json
        }
    }

    private enum MediaCopyJobFile {
        static let fileExtension = "job"

        static var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .json
        }
    }

    private enum TrashEmergencyJournal {
        static let directoryName = "GPhilCoder"
        static let fileName = "trash-emergency-journal.json"
    }

    private enum TrashMoveRecordResult {
        case restoreLedgerRecorded
        case emergencyJournalOnly
    }

    private struct RestoreUnresolvedExportDocument: Encodable {
        let version: Int
        let exportedAt: Date
        let isPartialSearchSnapshot: Bool
        let deletedFolderPath: String?
        let backupRootPath: String?
        let restoreRootPath: String?
        let matchMode: String
        let hashMode: String
        let progressPhase: String?
        let progressDetail: String?
        let deletedCount: Int
        let restoredCount: Int
        let unresolvedListCount: Int
        let files: [RestoreUnresolvedFile]
    }

    private struct RestoreUnresolvedCopyResult: Sendable {
        var copied = 0
        var failed = 0
        var copiedURLs: [URL] = []
        var failedNames: [String] = []
    }

    private struct TrashableFileItem: Identifiable, Sendable {
        let id: UUID
        let url: URL
        let sourceRoot: URL?
        let relativeDirectory: String?
        let fileSizeBytes: Int64

        init(
            id: UUID = UUID(),
            url: URL,
            sourceRoot: URL?,
            relativeDirectory: String?,
            fileSizeBytes: Int64
        ) {
            self.id = id
            self.url = url
            self.sourceRoot = sourceRoot
            self.relativeDirectory = relativeDirectory
            self.fileSizeBytes = fileSizeBytes
        }

        init(audioInput item: AudioInputItem) {
            self.init(
                id: item.id,
                url: item.url,
                sourceRoot: item.sourceRoot,
                relativeDirectory: item.relativeDirectory,
                fileSizeBytes: item.fileSizeBytes
            )
        }

        init(deleteCandidate candidate: MediaDeleteCandidate) {
            self.init(
                url: candidate.sourceURL,
                sourceRoot: candidate.sourceRoot,
                relativeDirectory: candidate.relativeDirectory,
                fileSizeBytes: candidate.fileSizeBytes
            )
        }

        var name: String {
            url.lastPathComponent
        }
    }

    private struct MediaTrashResult: Sendable {
        var total: Int
        var moved = 0
        var failed = 0
        var emergencyOnly = 0
        var failedNames: [String] = []
        var cancelled = false

        init(total: Int = 0) {
            self.total = total
        }
    }

    private struct MediaRenameHistoryDocument: Codable, Sendable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var undoStack: [MediaRenameHistoryTransaction]
        var redoStack: [MediaRenameHistoryTransaction]
    }

    private struct MediaRenameHistoryItem: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let originalPath: String
        let renamedPath: String
        let originalName: String
        let renamedName: String
        let fileSizeBytes: Int64

        init(
            id: UUID = UUID(),
            originalPath: String,
            renamedPath: String,
            originalName: String,
            renamedName: String,
            fileSizeBytes: Int64
        ) {
            self.id = id
            self.originalPath = originalPath
            self.renamedPath = renamedPath
            self.originalName = originalName
            self.renamedName = renamedName
            self.fileSizeBytes = fileSizeBytes
        }
    }

    private struct MediaRenameHistoryTransaction: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let actionTitle: String
        let createdAt: Date
        let items: [MediaRenameHistoryItem]

        init(
            id: UUID = UUID(),
            actionTitle: String,
            createdAt: Date = Date(),
            items: [MediaRenameHistoryItem]
        ) {
            self.id = id
            self.actionTitle = actionTitle
            self.createdAt = createdAt
            self.items = items
        }

        func replacingItems(_ nextItems: [MediaRenameHistoryItem]) -> MediaRenameHistoryTransaction {
            MediaRenameHistoryTransaction(
                id: UUID(),
                actionTitle: actionTitle,
                createdAt: createdAt,
                items: nextItems
            )
        }
    }

    private struct MediaRenameResult: Sendable {
        var total: Int
        var renamed = 0
        var failed = 0
        var failedNames: [String] = []
        var historyItems: [MediaRenameHistoryItem] = []
        var cancelled = false

        init(total: Int = 0) {
            self.total = total
        }
    }

    private struct MediaRenameHistoryResult: Sendable {
        var total: Int
        var moved = 0
        var failed = 0
        var failedNames: [String] = []
        var movedItems: [MediaRenameHistoryItem] = []
        var cancelled = false

        init(total: Int = 0) {
            self.total = total
        }
    }

    private enum MediaRenameHistoryDirection: Equatable, Sendable {
        case undo
        case redo

        var title: String {
            switch self {
            case .undo:
                "Undo rename"
            case .redo:
                "Redo rename"
            }
        }

        var progressTitle: String {
            switch self {
            case .undo:
                "Undoing rename"
            case .redo:
                "Redoing rename"
            }
        }

        var progressVerb: String {
            switch self {
            case .undo:
                "reverted"
            case .redo:
                "redone"
            }
        }

        var notificationTitle: String {
            switch self {
            case .undo:
                "Rename undo finished"
            case .redo:
                "Rename redo finished"
            }
        }
    }

    @Published private(set) var inputs: [AudioInputItem] = []
    @Published private(set) var jobs: [EncodeJob] = []
    @Published var jobStateFilter: JobState?
    @Published private(set) var isEncoding = false
    @Published private(set) var ffmpegURL: URL?
    @Published private(set) var bundledFFmpegURL: URL?
    @Published private(set) var systemFFmpegURL: URL?
    @Published private(set) var ffmpegCapabilities = FFmpegCapabilities()
    @Published private(set) var systemFFmpegCapabilities = FFmpegCapabilities()
    @Published private(set) var statusMessage = "Add audio or video files to begin."
    @Published private(set) var notificationPermission: NotificationPermissionState = .unknown
    @Published private(set) var trashedSourceRecords: [TrashedSourceRecord] = [] {
        didSet { persistTrashedSourceRecords() }
    }
    @Published private(set) var pendingTrashSourceRecords: [PendingTrashSourceRecord] = []
    @Published var restoreDeletedFolder: URL? {
        didSet {
            persistOptionalDirectory(restoreDeletedFolder, forKey: DefaultsKey.restoreDeletedFolderPath)
            invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreDeletedFolder)
        }
    }
    @Published var restoreBackupRoot: URL? {
        didSet {
            persistOptionalDirectory(restoreBackupRoot, forKey: DefaultsKey.restoreBackupRootPath)
            invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreBackupRoot)
        }
    }
    @Published var restoreDestinationRoot: URL? {
        didSet {
            persistOptionalDirectory(
                restoreDestinationRoot,
                forKey: DefaultsKey.restoreDestinationRootPath
            )
            invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreDestinationRoot)
        }
    }
    @Published var restoreCopySource: RestoreCopySource = .deleted
    @Published var restoreMatchMode: RestoreMatchMode = .filenameAndSize {
        didSet { invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreMatchMode) }
    }
    @Published var restoreHashMode: RestoreHashMode = .auto {
        didSet { invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreHashMode) }
    }
    @Published var restoreOverwriteExisting = false
    @Published var restoreIncludeHidden = false {
        didSet { invalidateBackupRestorePlanIfChanged(from: oldValue, to: restoreIncludeHidden) }
    }
    @Published private(set) var restorePlanProgress: RestorePlanProgress?
    @Published private(set) var restorePlanLiveCounts: RestorePlanStatusCounts?
    @Published private(set) var restorePlanLiveUnresolvedItems: [RestoreUnresolvedFile] = []
    @Published private(set) var restorePlanScanSummary: RestorePlanScanSummary?
    @Published private(set) var restorePlanRecords: [RestorePlanRecord] = []
    @Published private(set) var isRestorePlanning = false
    @Published private(set) var isRestoringFromPlan = false
    @Published private(set) var restorePlanStoppedWithPartialResults = false
    @Published var fileManagementMode: FileManagementMode = .copy {
        didSet {
            guard oldValue != fileManagementMode else { return }
            UserDefaults.standard.set(fileManagementMode.rawValue, forKey: DefaultsKey.fileManagementMode)
            guard !isLoadingPersistedSettings else { return }
            refreshActiveFileManagementPreviewIfNeeded()
        }
    }
    @Published var mediaCopySourceRoots: [URL] = [] {
        didSet {
            persistMediaCopySourceRoots()
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: mediaCopySourceRoots)
        }
    }
    @Published var mediaCopyDestinationRoot: URL? {
        didSet {
            persistOptionalDirectory(
                mediaCopyDestinationRoot,
                forKey: DefaultsKey.mediaCopyDestinationRootPath
            )
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: mediaCopyDestinationRoot)
        }
    }
    @Published var mediaCopyFilter: MediaFileFilter = .audio {
        didSet {
            UserDefaults.standard.set(mediaCopyFilter.rawValue, forKey: DefaultsKey.mediaCopyFilter)
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: mediaCopyFilter)
        }
    }
    @Published private(set) var mediaCopyAudioExtensions: Set<String> =
        MediaFileFilter.audio.fileExtensions
    {
        didSet {
            persistMediaCopyExtensions(mediaCopyAudioExtensions, forKey: DefaultsKey.mediaCopyAudioExtensions)
            if mediaCopyFilter == .audio {
                invalidateMediaCopyPlanIfChanged(from: oldValue, to: mediaCopyAudioExtensions)
            }
        }
    }
    @Published private(set) var mediaCopyVideoExtensions: Set<String> =
        MediaFileFilter.video.fileExtensions
    {
        didSet {
            persistMediaCopyExtensions(mediaCopyVideoExtensions, forKey: DefaultsKey.mediaCopyVideoExtensions)
            if mediaCopyFilter == .video {
                invalidateMediaCopyPlanIfChanged(from: oldValue, to: mediaCopyVideoExtensions)
            }
        }
    }
    @Published var mediaFileNameFilterQuery = "" {
        didSet {
            UserDefaults.standard.set(mediaFileNameFilterQuery, forKey: DefaultsKey.mediaFileNameFilterQuery)
            handleMediaFileNameFilterChanged(
                from: oldValue.trimmingCharacters(in: .whitespacesAndNewlines),
                to: mediaFileNameFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
    @Published private(set) var mediaCopyPlan: MediaCopyPlan?
    @Published private(set) var mediaDeletePlan: MediaDeletePlan?
    @Published private(set) var mediaRenamePlan: MediaRenamePlan?
    @Published private(set) var isMediaRenamePreviewStale = false
    @Published private(set) var mediaCopyProgress: MediaCopyProgress?
    @Published private(set) var isMediaCopyScanning = false
    @Published private(set) var isMediaCopying = false
    @Published private(set) var isMediaDeleting = false
    @Published private(set) var isMediaRenaming = false
    @Published private(set) var mediaRenameProgressVerb = "renamed"
    @Published private(set) var mediaCopyQueue: [MediaCopyWorkflow] = []
    @Published private(set) var currentMediaCopyWorkflowID: UUID?
    @Published private var mediaRenameUndoStack: [MediaRenameHistoryTransaction] = [] {
        didSet { persistMediaRenameHistory() }
    }
    @Published private var mediaRenameRedoStack: [MediaRenameHistoryTransaction] = [] {
        didSet { persistMediaRenameHistory() }
    }
    @Published private(set) var encodingPresets: [EncodingPreset] = [] {
        didSet {
            guard !isLoadingPersistedSettings else { return }
            persistEncodingPresets()
        }
    }
    @Published private(set) var selectedAudioEncodingPresetID: UUID? {
        didSet {
            persistOptionalUUID(
                selectedAudioEncodingPresetID,
                forKey: DefaultsKey.selectedAudioEncodingPresetID
            )
        }
    }
    @Published private(set) var selectedVideoEncodingPresetID: UUID? {
        didSet {
            persistOptionalUUID(
                selectedVideoEncodingPresetID,
                forKey: DefaultsKey.selectedVideoEncodingPresetID
            )
        }
    }

    @Published var mediaRenameOperation: MediaRenameOperation = .pattern {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameOperation) }
    }
    @Published var mediaRenamePattern = "{name}" {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenamePattern) }
    }
    @Published var mediaRenameFindText = "" {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameFindText) }
    }
    @Published var mediaRenameReplacementText = "" {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameReplacementText) }
    }
    @Published var mediaRenameIsCaseSensitive = false {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameIsCaseSensitive) }
    }
    @Published var mediaRenameAddedText = "" {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameAddedText) }
    }
    @Published var mediaRenameTextPlacement: MediaRenameTextPlacement = .suffix {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameTextPlacement) }
    }
    @Published var mediaRenameCaseStyle: MediaRenameCaseStyle = .titleCase {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameCaseStyle) }
    }
    @Published var mediaRenameSort: MediaRenameSort = .name {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameSort) }
    }
    @Published var mediaRenameStartIndex = 1 {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameStartIndex) }
    }
    @Published var mediaRenameIndexStep = 1 {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameIndexStep) }
    }
    @Published var mediaRenameIndexPadding = 2 {
        didSet { handleMediaRenameSettingChanged(from: oldValue, to: mediaRenameIndexPadding) }
    }

    @Published private(set) var selectedInputExtensions: Set<String> = AudioFormat.inputExtensions {
        didSet {
            UserDefaults.standard.set(
                selectedInputExtensions.sorted(),
                forKey: DefaultsKey.selectedInputExtensions
            )
        }
    }

    @Published private(set) var selectedVideoInputExtensions: Set<String> = VideoFormat.inputExtensions {
        didSet {
            UserDefaults.standard.set(
                selectedVideoInputExtensions.sorted(),
                forKey: DefaultsKey.selectedVideoInputExtensions
            )
        }
    }

    @Published var encodingWorkflow: EncodingWorkflow = .audio {
        didSet {
            UserDefaults.standard.set(
                encodingWorkflow.rawValue,
                forKey: DefaultsKey.encodingWorkflow
            )
            if oldValue != encodingWorkflow {
                jobs.removeAll()
                jobStateFilter = nil
                statusMessage = activeFilterStatusMessage
            }
        }
    }

    @Published var outputMode: OutputMode = .sourceFolders {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: DefaultsKey.outputMode) }
    }

    @Published var exportFolder: URL? {
        didSet {
            if let exportFolder {
                UserDefaults.standard.set(
                    exportFolder.standardizedFileURL.path(percentEncoded: false),
                    forKey: DefaultsKey.exportFolderPath)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.exportFolderPath)
            }
        }
    }

    @Published var preserveSubfolders = true {
        didSet {
            UserDefaults.standard.set(preserveSubfolders, forKey: DefaultsKey.preserveSubfolders)
        }
    }

    @Published var overwriteExisting = false {
        didSet {
            UserDefaults.standard.set(overwriteExisting, forKey: DefaultsKey.overwriteExisting)
        }
    }

    @Published var outputFormat: AudioOutputFormat = .mp3 {
        didSet {
            UserDefaults.standard.set(outputFormat.rawValue, forKey: DefaultsKey.outputFormat)
        }
    }

    @Published var videoOutputContainer: VideoOutputContainer = .mp4 {
        didSet {
            UserDefaults.standard.set(
                videoOutputContainer.rawValue,
                forKey: DefaultsKey.videoOutputContainer
            )
        }
    }

    @Published var hevcPreset: HEVCVideoPreset = .balanced1080p {
        didSet {
            UserDefaults.standard.set(hevcPreset.rawValue, forKey: DefaultsKey.hevcPreset)
            if !isLoadingPersistedSettings {
                videoScaleMode = hevcPreset.defaultScaleMode
            }
        }
    }

    @Published var customVideoBitrateKbps = 8_000 {
        didSet {
            UserDefaults.standard.set(
                customVideoBitrateKbps,
                forKey: DefaultsKey.customVideoBitrateKbps
            )
        }
    }

    @Published var videoScaleMode: VideoScaleMode = HEVCVideoPreset.balanced1080p.defaultScaleMode {
        didSet {
            UserDefaults.standard.set(videoScaleMode.rawValue, forKey: DefaultsKey.videoScaleMode)
        }
    }

    @Published var videoAudioMode: VideoAudioMode = .copy {
        didSet {
            UserDefaults.standard.set(videoAudioMode.rawValue, forKey: DefaultsKey.videoAudioMode)
        }
    }

    @Published var videoHardwareDecodeMode: VideoHardwareDecodeMode = .auto {
        didSet {
            UserDefaults.standard.set(
                videoHardwareDecodeMode.rawValue,
                forKey: DefaultsKey.videoHardwareDecodeMode
            )
        }
    }

    @Published var mp3Mode: MP3EncodingMode = .vbr {
        didSet { UserDefaults.standard.set(mp3Mode.rawValue, forKey: DefaultsKey.mp3Mode) }
    }

    @Published var vbrQuality = 2 {
        didSet { UserDefaults.standard.set(vbrQuality, forKey: DefaultsKey.vbrQuality) }
    }

    @Published var cbrBitrateKbps = 320 {
        didSet { UserDefaults.standard.set(cbrBitrateKbps, forKey: DefaultsKey.cbrBitrateKbps) }
    }

    @Published var abrBitrateKbps = 192 {
        didSet { UserDefaults.standard.set(abrBitrateKbps, forKey: DefaultsKey.abrBitrateKbps) }
    }

    @Published var oggMode: OggEncodingOptions.Mode = .bitrate {
        didSet { UserDefaults.standard.set(oggMode.rawValue, forKey: DefaultsKey.oggMode) }
    }

    @Published var oggQuality = 6 {
        didSet { UserDefaults.standard.set(oggQuality, forKey: DefaultsKey.oggQuality) }
    }

    @Published var oggBitrateKbps = 256 {
        didSet { UserDefaults.standard.set(oggBitrateKbps, forKey: DefaultsKey.oggBitrateKbps) }
    }

    @Published var opusRateMode: OpusEncodingOptions.RateMode = .vbr {
        didSet {
            UserDefaults.standard.set(opusRateMode.rawValue, forKey: DefaultsKey.opusRateMode)
        }
    }

    @Published var opusBitrateKbps = 192 {
        didSet { UserDefaults.standard.set(opusBitrateKbps, forKey: DefaultsKey.opusBitrateKbps) }
    }

    @Published var flacCompressionLevel = 8 {
        didSet {
            UserDefaults.standard.set(
                flacCompressionLevel, forKey: DefaultsKey.flacCompressionLevel)
        }
    }

    @Published var splitOversizedMultichannel = true {
        didSet {
            UserDefaults.standard.set(
                splitOversizedMultichannel,
                forKey: DefaultsKey.splitOversizedMultichannel
            )
        }
    }

    @Published var parallelJobs = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) {
        didSet { UserDefaults.standard.set(parallelJobs, forKey: DefaultsKey.parallelJobs) }
    }

    @Published var ffmpegThreads = 0 {
        didSet { UserDefaults.standard.set(ffmpegThreads, forKey: DefaultsKey.ffmpegThreads) }
    }

    @Published var ffmpegSourcePreference: FFmpegSourcePreference = .bundled {
        didSet {
            UserDefaults.standard.set(
                ffmpegSourcePreference.rawValue,
                forKey: DefaultsKey.ffmpegSourcePreference
            )
            if oldValue != ffmpegSourcePreference {
                refreshFFmpeg()
            }
        }
    }

    private var encodeTask: Task<Void, Never>?
    private var restorePlanTask: Task<Void, Never>?
    private var restoreApplyTask: Task<Void, Never>?
    private var mediaCopyTask: Task<Void, Never>?
    private var mediaFileNameFilterRefreshTask: Task<Void, Never>?
    private var isLoadingPersistedSettings = false
    private var mediaFileInventory: [MediaFileInventoryRecord] = []
    private var mediaFileInventorySourceRootPaths: [String] = []

    var processorLimit: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    var canEncode: Bool {
        !activeInputs.isEmpty && !isEncoding && encodingFFmpegURL != nil
            && (outputMode == .sourceFolders || exportFolder != nil)
    }

    var canSaveQueue: Bool {
        !queueItemsForActions.isEmpty && !isEncoding
    }

    var canTrashQueueSources: Bool {
        !queueItemsForActions.isEmpty && !isEncoding
    }

    var completedCount: Int {
        jobs.filter { $0.state == .succeeded }.count
    }

    var failedCount: Int {
        jobs.filter { $0.state == .failed }.count
    }

    var skippedCount: Int {
        jobs.filter { $0.state == .skipped }.count
    }

    var runningCount: Int {
        jobs.filter { $0.state == .running }.count
    }

    var queuedCount: Int {
        jobs.filter { $0.state == .queued }.count
    }

    var visibleJobs: [EncodeJob] {
        guard let jobStateFilter else { return jobs }
        return jobs.filter { $0.state == jobStateFilter }
    }

    var visibleJobCount: Int {
        visibleJobs.count
    }

    var jobStateFilterTitle: String? {
        jobStateFilter?.filterTitle
    }

    var queueItemsForActions: [AudioInputItem] {
        guard !jobs.isEmpty, jobStateFilter != nil else { return activeInputs }
        let visibleItemIDs = Set(visibleJobs.map(\.item.id))
        return activeInputs.filter { visibleItemIDs.contains($0.id) }
    }

    var totalInputSize: Int64 {
        inputs.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var activeInputs: [AudioInputItem] {
        inputs.filter { isSelectedInput($0.url) }
    }

    var inactiveInputCount: Int {
        inputs.count - activeInputs.count
    }

    var activeInputSize: Int64 {
        activeInputs.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var sameFormatInputCount: Int {
        activeInputs.filter { $0.url.pathExtension.lowercased() == outputFileExtension }.count
    }

    var sameFormatWarningMessage: String? {
        guard sameFormatInputCount > 0 else { return nil }
        let extensionLabel = outputFileExtension
        let noun = sameFormatInputCount == 1 ? "source already uses" : "sources already use"
        return
            "\(sameFormatInputCount) \(noun) .\(extensionLabel). Same-format exports are written with \"-encoded\" before the extension, and exact source overwrites are blocked."
    }

    var lossyToLosslessWarningMessage: String? {
        guard encodingWorkflow == .audio else { return nil }
        guard outputFormat.isLossless else { return nil }
        let lossyExtensions: Set<String> = ["aac", "m4a", "mp3", "ogg", "opus"]
        let lossyInputCount = activeInputs.filter {
            lossyExtensions.contains($0.url.pathExtension.lowercased())
        }.count
        guard lossyInputCount > 0 else { return nil }

        let noun = lossyInputCount == 1 ? "source appears" : "sources appear"
        return
            "\(lossyInputCount) \(noun) to be lossy. \(outputFormat.title) output will be lossless only from the already-compressed signal; it cannot restore detail lost during earlier lossy encoding."
    }

    var nativeOggReencodeWarningMessage: String? {
        guard encodingWorkflow == .audio else { return nil }
        guard outputFormat == .ogg,
              sameFormatInputCount > 0,
              !supportsOggBitrate
        else {
            return nil
        }

        return "This FFmpeg build is using the native Vorbis encoder. Ogg-to-Ogg re-encoding may fail on some files; install an FFmpeg build with libvorbis for the most reliable Ogg output."
    }

    var supportsOggBitrate: Bool {
        ffmpegCapabilities.hasLibVorbis
    }

    var supportsHEVCVideoToolbox: Bool {
        systemFFmpegCapabilities.hasHEVCVideoToolbox
    }

    var selectedEncoderName: String {
        if encodingWorkflow == .video {
            return "hevc_videotoolbox"
        }

        return switch outputFormat {
        case .ogg:
            supportsOggBitrate ? "libvorbis" : "vorbis"
        default:
            outputFormat.codecName
        }
    }

    var videoEncodeModeTitle: String {
        supportsHEVCVideoToolbox ? "Encode: HW only" : "Encode: no HW"
    }

    var videoEncodeModeDetail: String {
        supportsHEVCVideoToolbox
            ? "VideoToolbox HEVC, software fallback blocked"
            : "System FFmpeg has no hevc_videotoolbox"
    }

    var videoDecodeModeTitle: String {
        switch videoHardwareDecodeMode {
        case .auto:
            "Decode: HW auto"
        case .on:
            "Decode: HW preferred"
        case .off:
            "Decode: SW"
        }
    }

    var videoDecodeModeDetail: String {
        switch videoHardwareDecodeMode {
        case .auto:
            "VideoToolbox requested when FFmpeg can use it"
        case .on:
            "VideoToolbox requested for this job"
        case .off:
            "FFmpeg software decoder path"
        }
    }

    var videoScaleModeTitle: String {
        switch videoScaleMode {
        case .source:
            "Scale: off"
        case .max1080p:
            "Scale: SW 1080p"
        case .max4k:
            "Scale: SW 4K"
        }
    }

    var videoScaleModeDetail: String {
        switch videoScaleMode {
        case .source:
            "No resize filter; source dimensions are preserved"
        case .max1080p, .max4k:
            "\(videoScaleMode.detail) FFmpeg performs this scale filter in software before VideoToolbox encode."
        }
    }

    var selectedInputReadableList: String {
        switch encodingWorkflow {
        case .audio:
            return selectedAudioInputReadableList
        case .video:
            return selectedVideoInputReadableList
        }
    }

    var selectedAudioInputReadableList: String {
        if selectedInputExtensions == AudioFormat.inputExtensions {
            return "All formats"
        }

        let selectedFormats = InputAudioFormat.allCases
            .filter { !$0.fileExtensions.isDisjoint(with: selectedInputExtensions) }
            .map(\.title)

        return selectedFormats.isEmpty ? "None" : selectedFormats.joined(separator: ", ")
    }

    var selectedVideoInputReadableList: String {
        if selectedVideoInputExtensions == VideoFormat.inputExtensions {
            return "All formats"
        }

        let selectedFormats = InputVideoFormat.allCases
            .filter { !$0.fileExtensions.isDisjoint(with: selectedVideoInputExtensions) }
            .map(\.title)

        return selectedFormats.isEmpty ? "None" : selectedFormats.joined(separator: ", ")
    }

    var hasSelectedInputFilters: Bool {
        switch encodingWorkflow {
        case .audio:
            !selectedInputExtensions.isEmpty
        case .video:
            !selectedVideoInputExtensions.isEmpty
        }
    }

    var workflowEncodingPresets: [EncodingPreset] {
        encodingPresets
            .filter { $0.workflow == encodingWorkflow }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedEncodingPresetID: UUID? {
        switch encodingWorkflow {
        case .audio:
            selectedAudioEncodingPresetID
        case .video:
            selectedVideoEncodingPresetID
        }
    }

    var selectedEncodingPreset: EncodingPreset? {
        guard let selectedEncodingPresetID else { return nil }
        return encodingPresets.first { $0.id == selectedEncodingPresetID }
    }

    var selectedEncodingPresetSummary: String {
        selectedEncodingPreset?.summary ?? "No preset selected"
    }

    var canLoadSelectedEncodingPreset: Bool {
        selectedEncodingPreset != nil && !isEncoding
    }

    var canUpdateSelectedEncodingPreset: Bool {
        selectedEncodingPreset != nil && !isEncoding
    }

    var canDeleteSelectedEncodingPreset: Bool {
        selectedEncodingPreset != nil && !isEncoding
    }

    /// True when the working settings differ from the active preset's stored
    /// settings. Encoding reads the live settings, not the preset, so this tells
    /// the user that the selected preset no longer describes what will run.
    /// No preset selected, or a preset missing settings for its own workflow,
    /// counts as not dirty.
    var isLoadedPresetDirty: Bool {
        guard let preset = selectedEncodingPreset else { return false }
        switch preset.workflow {
        case .audio:
            return makeAudioPresetSettings() != preset.audio
        case .video:
            return makeVideoPresetSettings() != preset.video
        }
    }

    var canRestoreTrashedSources: Bool {
        !isEncoding && !isMediaCopyBusy && !trashedSourceRecords.isEmpty
    }

    var canClearTrashedSourceRecords: Bool {
        !isEncoding && !isMediaCopyBusy && !trashedSourceRecords.isEmpty
    }

    var canBuildBackupRestorePlan: Bool {
        restoreDeletedFolder != nil && restoreBackupRoot != nil && restoreDestinationRoot != nil
            && !isRestorePlanning && !isRestoringFromPlan
    }

    var canApplyBackupRestorePlan: Bool {
        restorePlanRestorableCount > 0 && !isRestorePlanning && !isRestoringFromPlan
    }

    var canExportRestoreUnresolvedItems: Bool {
        !restoreUnresolvedExportItems.isEmpty
    }

    var canCopyRestoreUnresolvedItemsToRestoreRoot: Bool {
        restoreDestinationRoot != nil && !restoreUnresolvedExportItems.isEmpty
            && !isRestorePlanning && !isRestoringFromPlan
    }

    var isMediaCopyBusy: Bool {
        isMediaCopyScanning || isMediaCopying || isMediaDeleting || isMediaRenaming
    }

    var isQuitBlockedByActiveProcess: Bool {
        isEncoding || isMediaCopyBusy
    }

    var activeProcessQuitBlockedMessage: String {
        if isEncoding {
            return "Encoding is still running. Cancel encoding or wait for it to finish before closing GPhil Coder."
        }

        if isMediaCopyBusy {
            return "A file management operation is still running. Cancel it or wait for it to finish before closing GPhil Coder."
        }

        return "An active process is still running. Wait for it to finish before closing GPhil Coder."
    }

    func reportQuitBlockedByActiveProcess() {
        statusMessage = activeProcessQuitBlockedMessage
    }

    var canPrepareMediaCopy: Bool {
        fileManagementMode == .copy
            && primaryMediaCopySourceRoot != nil && mediaCopyDestinationRoot != nil
            && mediaCopyHasSelectedExtensionsForCurrentFilter && !isMediaCopyBusy
    }

    var canRefreshMediaDeletePreview: Bool {
        fileManagementMode == .delete
            && !mediaCopySourceRoots.isEmpty
            && mediaCopyHasSelectedExtensionsForCurrentFilter
            && !isMediaCopyBusy
    }

    var canDeleteFilteredMediaFiles: Bool {
        fileManagementMode == .delete
            && mediaDeletePlan?.hasDeletableContent == true
            && currentMediaDeletePlanMatchesFilters
            && !isMediaCopyBusy
    }

    var canRefreshMediaRenamePreview: Bool {
        fileManagementMode == .rename
            && !mediaCopySourceRoots.isEmpty
            && mediaCopyHasSelectedExtensionsForCurrentFilter
            && !isMediaCopyBusy
    }

    var canRenameFilteredMediaFiles: Bool {
        fileManagementMode == .rename
            && (mediaRenamePlan?.readyCount ?? 0) > 0
            && mediaRenamePlan?.blockedCount == 0
            && !isMediaRenamePreviewStale
            && !isMediaCopyBusy
    }

    var canUndoMediaRename: Bool {
        fileManagementMode == .rename && !mediaRenameUndoStack.isEmpty && !isMediaCopyBusy
    }

    var canRedoMediaRename: Bool {
        fileManagementMode == .rename && !mediaRenameRedoStack.isEmpty && !isMediaCopyBusy
    }

    var mediaRenameUndoButtonTitle: String {
        guard let transaction = mediaRenameUndoStack.last else { return "Undo" }
        return "Undo (\(transaction.items.count))"
    }

    var mediaRenameRedoButtonTitle: String {
        guard let transaction = mediaRenameRedoStack.last else { return "Redo" }
        return "Redo (\(transaction.items.count))"
    }

    var mediaRenameUndoHelp: String {
        guard let transaction = mediaRenameUndoStack.last else {
            return "No rename action to undo"
        }
        return "Move \(transaction.items.count) file\(transaction.items.count == 1 ? "" : "s") back to their previous name"
    }

    var mediaRenameRedoHelp: String {
        guard let transaction = mediaRenameRedoStack.last else {
            return "No rename action to redo"
        }
        return "Reapply \(transaction.items.count) previously undone rename\(transaction.items.count == 1 ? "" : "s")"
    }

    var canAddMediaCopyWorkflowToQueue: Bool {
        fileManagementMode == .copy
            && !mediaCopySourceRoots.isEmpty && mediaCopyDestinationRoot != nil
            && mediaCopyHasSelectedExtensionsForCurrentFilter && !isMediaCopyBusy
    }

    var availableMediaFileFilters: [MediaFileFilter] {
        MediaFileFilter.allCases
    }

    var activeMediaMatchedCount: Int {
        switch fileManagementMode {
        case .copy:
            mediaCopyPlan?.candidateCount ?? 0
        case .delete:
            mediaDeletePlan?.candidateCount ?? 0
        case .rename:
            mediaRenamePlan?.itemCount ?? 0
        }
    }

    var activeMediaTotalSize: Int64 {
        switch fileManagementMode {
        case .copy:
            mediaCopyPlan?.totalSizeBytes ?? 0
        case .delete:
            mediaDeletePlan?.totalSizeBytes ?? 0
        case .rename:
            mediaRenamePlan?.totalSizeBytes ?? 0
        }
    }

    var activeMediaPreviewSymbolName: String {
        switch fileManagementMode {
        case .copy:
            mediaCopyFilter.symbolName
        case .delete:
            "trash"
        case .rename:
            "pencil"
        }
    }

    var activeMediaPlanTitle: String {
        switch fileManagementMode {
        case .copy:
            "File Copy Plan"
        case .delete:
            "Filtered Delete Plan"
        case .rename:
            "Rename Preview"
        }
    }

    var activeMediaActionName: String {
        switch fileManagementMode {
        case .copy:
            "copy"
        case .delete:
            "delete"
        case .rename:
            "rename"
        }
    }

    var canRunMediaCopyQueue: Bool {
        !mediaCopyQueue.isEmpty && !isMediaCopyBusy
    }

    var canSaveMediaCopyJob: Bool {
        !mediaCopyQueue.isEmpty && !isMediaCopyBusy
    }

    var mediaCopyMatchedCount: Int {
        mediaCopyPlan?.candidateCount ?? 0
    }

    var mediaCopyConflictCount: Int {
        mediaCopyPlan?.conflictCount ?? 0
    }

    var mediaCopyTotalSize: Int64 {
        mediaCopyPlan?.totalSizeBytes ?? 0
    }

    var mediaCopyPreviewItems: [MediaCopyCandidate] {
        guard let plan = mediaCopyPlan else { return [] }
        return plan.candidates
    }

    var mediaDeletePreviewItems: [MediaDeleteCandidate] {
        guard let plan = mediaDeletePlan else { return [] }
        return plan.candidates
    }

    var mediaRenamePreviewItems: [MediaRenameItem] {
        guard let plan = mediaRenamePlan else { return [] }
        return plan.items
    }

    var mediaRenameReadyCount: Int {
        mediaRenamePlan?.readyCount ?? 0
    }

    var mediaRenameBlockedCount: Int {
        mediaRenamePlan?.blockedCount ?? 0
    }

    var mediaRenameUnchangedCount: Int {
        mediaRenamePlan?.unchangedCount ?? 0
    }

    var mediaCopyExtensionOptions: [String] {
        mediaCopyFilter.fileExtensions.sorted()
    }

    var mediaCopySelectedExtensionSummary: String {
        mediaCopyFilter.readableExtensionList(selectedExtensions: currentMediaCopySelectedExtensions)
    }

    var mediaFileNameFilterSummary: String {
        let query = currentMediaFileNameFilter.trimmedQuery
        guard !query.isEmpty else { return "Any file name" }
        return "Name contains \"\(query)\""
    }

    var mediaCopyExtensionMenuTitle: String {
        guard mediaCopyFilter.supportsExtensionSelection else { return "All files" }
        let selectedExtensions = currentMediaCopySelectedExtensions
        guard !selectedExtensions.isEmpty else { return "No extensions selected" }
        guard selectedExtensions != mediaCopyFilter.fileExtensions else {
            return "All \(mediaCopyFilter.title.lowercased()) extensions"
        }
        if selectedExtensions.count == 1, let onlyExtension = selectedExtensions.first {
            return ".\(onlyExtension)"
        }
        return "\(selectedExtensions.count) extensions selected"
    }

    var mediaCopyDeleteSummary: String {
        guard mediaCopyFilter.supportsExtensionSelection else {
            return "all files"
        }
        return "\(mediaCopyFilter.title.lowercased()) files matching \(mediaCopySelectedExtensionSummary)"
    }

    var mediaCopyQueueTotalCount: Int {
        mediaCopyQueue.count
    }

    var primaryMediaCopySourceRoot: URL? {
        mediaCopySourceRoots.first
    }

    var mediaCopySourceSummary: String {
        switch mediaCopySourceRoots.count {
        case 0:
            return "No source folder selected"
        case 1:
            return mediaCopySourceRoots[0].path(percentEncoded: false)
        default:
            return "\(mediaCopySourceRoots.count) source folders selected"
        }
    }

    var mediaCopySourceDetail: String? {
        guard mediaCopySourceRoots.count > 1 else { return nil }
        return mediaCopySourceRoots
            .prefix(3)
            .map { $0.lastPathComponent }
            .joined(separator: ", ")
            + (mediaCopySourceRoots.count > 3 ? "..." : "")
    }

    var restorePlanAlreadyRestoredCount: Int {
        restorePlanLiveCounts?.alreadyRestored
            ?? restorePlanRecords.filter { $0.status == .alreadyRestored }.count
    }

    var restorePlanDeletedCount: Int {
        if let deletedTotal = restorePlanLiveCounts?.deletedTotal, deletedTotal > 0 {
            return deletedTotal
        }
        if let scanSummary = restorePlanScanSummary {
            return scanSummary.deletedFileCount
        }
        return restorePlanRecords.count
    }

    var restorePlanUnresolvedCount: Int {
        if let liveCounts = restorePlanLiveCounts, liveCounts.deletedTotal > 0 {
            return liveCounts.unresolvedFromRestore
        }
        if let scanSummary = restorePlanScanSummary {
            return scanSummary.unresolvedFileCount
        }
        return 0
    }

    var restorePlanMatchedCount: Int {
        restorePlanLiveCounts?.matched ?? restorePlanRecords.filter { $0.status == .matched }.count
    }

    var restorePlanConflictCount: Int {
        restorePlanLiveCounts?.conflict
            ?? restorePlanRecords.filter { $0.status == .matchedConflict }.count
    }

    var restorePlanAmbiguousCount: Int {
        restorePlanLiveCounts?.ambiguous
            ?? restorePlanRecords.filter { $0.status == .ambiguous }.count
    }

    var restorePlanMissingCount: Int {
        restorePlanLiveCounts?.missing ?? restorePlanRecords.filter { $0.status == .missing }.count
    }

    var restorePlanRestorableCount: Int {
        restorePlanMatchedCount + (restoreOverwriteExisting ? restorePlanConflictCount : 0)
    }

    private var restoreUnresolvedExportItems: [RestoreUnresolvedFile] {
        if !restorePlanLiveUnresolvedItems.isEmpty {
            return restorePlanLiveUnresolvedItems
        }

        return restorePlanRecords.compactMap { record in
            guard record.status == .missing || record.status == .ambiguous else { return nil }
            return RestoreUnresolvedFile(
                id: record.deletedURL.standardizedFileURL.path,
                name: record.displayName,
                matchName: nil,
                deletedPath: record.deletedURL.path(percentEncoded: false),
                size: record.size
            )
        }
    }

    private var currentMediaCopySelectedExtensions: Set<String> {
        selectedExtensions(for: mediaCopyFilter) ?? []
    }

    private var currentMediaFileNameFilter: MediaFileNameFilter {
        MediaFileNameFilter(query: mediaFileNameFilterQuery)
    }

    private var currentMediaDeletePlanMatchesFilters: Bool {
        guard let mediaDeletePlan else { return false }
        return mediaDeletePlan.sourceRoots.map { $0.standardizedFileURL.path }
            == currentMediaCopySourceRootPaths
            && mediaDeletePlan.filter == mediaCopyFilter
            && mediaDeletePlan.selectedExtensions == currentMediaCopySelectedExtensions
            && mediaDeletePlan.fileNameFilter == currentMediaFileNameFilter
    }

    private var mediaCopyHasSelectedExtensionsForCurrentFilter: Bool {
        !mediaCopyFilter.supportsExtensionSelection || !currentMediaCopySelectedExtensions.isEmpty
    }

    private var currentMediaCopySourceRootPaths: [String] {
        mediaCopySourceRoots.map { $0.standardizedFileURL.path }
    }

    private var mediaFileInventoryMatchesCurrentSources: Bool {
        !mediaCopySourceRoots.isEmpty
            && mediaFileInventorySourceRootPaths == currentMediaCopySourceRootPaths
    }

    private func currentMediaRenameSettings() -> MediaRenameSettings {
        MediaRenameSettings(
            operation: mediaRenameOperation,
            pattern: mediaRenamePattern,
            findText: mediaRenameFindText,
            replacementText: mediaRenameReplacementText,
            isCaseSensitive: mediaRenameIsCaseSensitive,
            addedText: mediaRenameAddedText,
            textPlacement: mediaRenameTextPlacement,
            caseStyle: mediaRenameCaseStyle,
            sort: mediaRenameSort,
            startIndex: mediaRenameStartIndex,
            indexStep: mediaRenameIndexStep,
            indexPadding: mediaRenameIndexPadding
        )
    }

    var activeFilterStatusMessage: String {
        if inputs.isEmpty {
            return "Input filter set to \(selectedInputReadableList)."
        }

        let activeCount = activeInputs.count
        let hiddenCount = inactiveInputCount
        if hiddenCount == 0 {
            return "Input filter set to \(selectedInputReadableList). \(activeCount) queued \(encodingWorkflow.queueNoun)\(activeCount == 1 ? "" : "s") active."
        }

        return "Input filter set to \(selectedInputReadableList). \(activeCount) active, \(hiddenCount) hidden until their formats are re-enabled."
    }

    var outputFormatTitle: String {
        switch encodingWorkflow {
        case .audio:
            outputFormat.title
        case .video:
            videoOutputContainer.title
        }
    }

    var outputFileExtension: String {
        switch encodingWorkflow {
        case .audio:
            outputFormat.fileExtension
        case .video:
            videoOutputContainer.fileExtension
        }
    }

    var outputFormatDetail: String {
        switch encodingWorkflow {
        case .audio:
            outputFormat.detail
        case .video:
            videoOutputContainer.detail
        }
    }

    var videoBitrateKbps: Int {
        hevcPreset == .custom ? customVideoBitrateKbps : hevcPreset.defaultBitrateKbps
    }

    var videoEncodingWarningMessage: String? {
        guard encodingWorkflow == .video, !supportsHEVCVideoToolbox else { return nil }
        return "This FFmpeg build does not report hevc_videotoolbox. Select a VideoToolbox-capable FFmpeg before starting video encoding."
    }

    var ffmpegSourceTitle: String {
        if encodingWorkflow == .video {
            return "System"
        }
        return ffmpegSourcePreference.title
    }

    var activeFFmpegPath: String {
        encodingFFmpegURL?.path(percentEncoded: false) ?? "No executable selected"
    }

    var encodingFFmpegURL: URL? {
        switch encodingWorkflow {
        case .audio:
            ffmpegURL
        case .video:
            systemFFmpegURL
        }
    }

    private var pendingTrashJournalNotice: String {
        guard !pendingTrashSourceRecords.isEmpty else { return "" }
        return
            " Emergency trash journal contains \(pendingTrashSourceRecords.count) source path\(pendingTrashSourceRecords.count == 1 ? "" : "s")."
    }

    init() {
        loadPersistedSettings()
        refreshFFmpeg()
        refreshNotificationPermission()
        refreshActiveFileManagementPreviewIfNeeded()
    }

    func refreshNotificationPermission() {
        AppNotifier.refreshAuthorization { [weak self] state in
            self?.notificationPermission = state
        }
    }

    func requestNotificationPermission() {
        AppNotifier.requestAuthorization { [weak self] state, errorMessage in
            self?.notificationPermission = state
            if let errorMessage {
                self?.statusMessage =
                    "Could not request notification permission: \(errorMessage)."
                AppNotifier.openNotificationSettings()
                return
            }

            switch state {
            case .enabled:
                self?.statusMessage =
                    "Notifications enabled. Completion alerts appear when GPhilCoder is in the background."
            case .denied:
                AppNotifier.openNotificationSettings()
                self?.statusMessage =
                    "Notifications are denied. Opened macOS Notification settings so you can enable GPhilCoder there."
            case .notDetermined, .unknown:
                self?.statusMessage =
                    "Notification permission was not granted. Check macOS notification settings."
            }
        }
    }

    func sendTestNotification() {
        AppNotifier.sendTestNotification { [weak self] errorMessage in
            if let errorMessage {
                self?.statusMessage = "Could not send test notification: \(errorMessage)"
            } else {
                self?.statusMessage = "Sent a test notification."
            }
            self?.refreshNotificationPermission()
        }
    }

    func openNotificationSettings() {
        AppNotifier.openNotificationSettings()
        statusMessage =
            "Opened macOS Notification settings. If GPhilCoder is not selected automatically, choose it there and enable notifications."
        refreshNotificationPermission()
    }

    func refreshFFmpeg() {
        bundledFFmpegURL = FFmpegLocator.bundledFFmpegURL()
        systemFFmpegURL = FFmpegLocator.systemFFmpegURL()
        ffmpegURL = FFmpegLocator.locate(preference: ffmpegSourcePreference)
        if let systemFFmpegURL {
            systemFFmpegCapabilities = FFmpegCapabilities.detect(ffmpegURL: systemFFmpegURL)
        } else {
            systemFFmpegCapabilities = FFmpegCapabilities()
        }

        if let ffmpegURL {
            ffmpegCapabilities = FFmpegCapabilities.detect(ffmpegURL: ffmpegURL)
            let vorbisStatus =
                ffmpegCapabilities.hasLibVorbis ? "libvorbis available" : "native Vorbis only"
            let videoStatus =
                systemFFmpegCapabilities.hasHEVCVideoToolbox
                ? "HEVC VideoToolbox available"
                : "HEVC VideoToolbox unavailable"
            let source = FFmpegLocator.isBundled(ffmpegURL) ? "bundled FFmpeg" : "system FFmpeg"
            statusMessage =
                "Audio uses \(source) at \(ffmpegURL.path(percentEncoded: false)) (\(vorbisStatus)). Video uses system FFmpeg (\(videoStatus)).\(pendingTrashJournalNotice)"
        } else {
            ffmpegCapabilities = FFmpegCapabilities()
            switch ffmpegSourcePreference {
            case .bundled:
                statusMessage =
                    "Bundled FFmpeg was not found in this app. Select System FFmpeg or rebuild the app with BUNDLED_FFMPEG.\(pendingTrashJournalNotice)"
            case .system:
                statusMessage = FFmpegToolError.notFound.localizedDescription + pendingTrashJournalNotice
            }
        }
    }

    func isFFmpegSourceAvailable(_ source: FFmpegSourcePreference) -> Bool {
        switch source {
        case .bundled:
            bundledFFmpegURL != nil
        case .system:
            systemFFmpegURL != nil
        }
    }

    func ffmpegPath(for source: FFmpegSourcePreference) -> String {
        switch source {
        case .bundled:
            bundledFFmpegURL?.path(percentEncoded: false) ?? "Not bundled in this build"
        case .system:
            systemFFmpegURL?.path(percentEncoded: false) ?? "Not found on this Mac"
        }
    }

    func setSelectedEncodingPresetID(_ id: UUID?) {
        setSelectedEncodingPresetID(id, for: encodingWorkflow)
    }

    func setSelectedEncodingPresetID(_ id: UUID?, for workflow: EncodingWorkflow) {
        switch workflow {
        case .audio:
            selectedAudioEncodingPresetID = id
        case .video:
            selectedVideoEncodingPresetID = id
        }
    }

    func loadSelectedEncodingPreset() {
        guard let preset = selectedEncodingPreset else {
            statusMessage = "Choose a preset before loading."
            return
        }
        applyEncodingPreset(preset)
    }

    func loadEncodingPreset(_ preset: EncodingPreset) {
        applyEncodingPreset(preset)
    }

    func saveCurrentSettingsAsEncodingPreset() {
        guard !isEncoding else { return }
        guard let name = promptEncodingPresetName(
            title: "Save Encoding Preset",
            message: "Name this \(encodingWorkflow.title.lowercased()) encoding preset.",
            defaultName: defaultEncodingPresetName()
        ) else {
            return
        }

        let preset = currentEncodingPreset(named: name)
        encodingPresets.append(preset)
        setSelectedEncodingPresetID(preset.id)
        statusMessage = "Saved \(encodingWorkflow.title.lowercased()) preset \(preset.name)."
    }

    func updateSelectedEncodingPreset() {
        guard !isEncoding else { return }
        guard let preset = selectedEncodingPreset,
            let index = encodingPresets.firstIndex(where: { $0.id == preset.id })
        else {
            statusMessage = "Choose a preset before updating."
            return
        }

        encodingPresets[index] = currentEncodingPreset(
            id: preset.id,
            named: preset.name,
            createdAt: preset.createdAt
        )
        statusMessage = "Updated preset \(preset.name)."
    }

    func renameSelectedEncodingPreset() {
        guard !isEncoding else { return }
        guard let preset = selectedEncodingPreset else { return }
        renameEncodingPreset(preset)
    }

    func renameEncodingPreset(_ preset: EncodingPreset) {
        guard !isEncoding else { return }
        guard let index = encodingPresets.firstIndex(where: { $0.id == preset.id }),
            let name = promptEncodingPresetName(
                title: "Rename Encoding Preset",
                message: "Rename this preset.",
                defaultName: preset.name
            )
        else {
            return
        }

        encodingPresets[index].name = name
        encodingPresets[index].updatedAt = Date()
        statusMessage = "Renamed preset to \(name)."
    }

    func updateEncodingPreset(_ preset: EncodingPreset) {
        guard preset.workflow == encodingWorkflow else {
            statusMessage =
                "Switch to the \(preset.workflow.title) workflow before updating \(preset.name)."
            return
        }
        setSelectedEncodingPresetID(preset.id, for: preset.workflow)
        updateSelectedEncodingPreset()
    }

    func deleteSelectedEncodingPreset() {
        guard let preset = selectedEncodingPreset else {
            statusMessage = "Choose a preset before deleting."
            return
        }
        deleteEncodingPreset(preset)
    }

    func deleteEncodingPreset(_ preset: EncodingPreset) {
        guard !isEncoding else { return }
        guard confirmDeleteEncodingPreset(preset) else { return }

        encodingPresets.removeAll { $0.id == preset.id }
        if selectedAudioEncodingPresetID == preset.id {
            selectedAudioEncodingPresetID = nil
        }
        if selectedVideoEncodingPresetID == preset.id {
            selectedVideoEncodingPresetID = nil
        }
        statusMessage = "Deleted preset \(preset.name)."
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add \(encodingWorkflow.title) Files"
        panel.prompt = "Add Files"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = currentSupportedInputExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = lastInputDirectoryURL()

        guard panel.runModal() == .OK else { return }
        rememberInputDirectory(fromFiles: panel.urls)
        let summary = addFileURLs(panel.urls)
        statusMessage = queueAddStatusMessage(for: summary)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Folder"
        panel.prompt = "Add Folder"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = lastInputDirectoryURL()

        guard panel.runModal() == .OK else { return }
        rememberInputDirectory(panel.urls.first)

        var combined = AddSummary()
        for folder in panel.urls {
            let summary = addFolderURL(folder)
            combined.added += summary.added
            combined.duplicates += summary.duplicates
            combined.unsupported += summary.unsupported
        }
        statusMessage = queueAddStatusMessage(for: combined)
    }

    func toggleInputFormat(_ format: InputAudioFormat) {
        guard !isEncoding else { return }
        setInputFormat(format, enabled: !isInputFormatEnabled(format))
    }

    func toggleInputFormat(_ format: InputVideoFormat) {
        guard !isEncoding else { return }
        setInputFormat(format, enabled: !isInputFormatEnabled(format))
    }

    func setInputFormat(_ format: InputAudioFormat, enabled: Bool) {
        guard !isEncoding else { return }
        if enabled {
            selectedInputExtensions.formUnion(format.fileExtensions)
        } else {
            selectedInputExtensions.subtract(format.fileExtensions)
        }
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = activeFilterStatusMessage
    }

    func setInputFormat(_ format: InputVideoFormat, enabled: Bool) {
        guard !isEncoding else { return }
        if enabled {
            selectedVideoInputExtensions.formUnion(format.fileExtensions)
        } else {
            selectedVideoInputExtensions.subtract(format.fileExtensions)
        }
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = activeFilterStatusMessage
    }

    func toggleJobStateFilter(_ state: JobState) {
        guard !jobs.isEmpty else { return }
        jobStateFilter = jobStateFilter == state ? nil : state
        if let jobStateFilter {
            statusMessage =
                "Showing \(visibleJobCount) \(jobStateFilter.filterTitle.lowercased()) job\(visibleJobCount == 1 ? "" : "s"). Queue actions use this filtered set."
        } else {
            statusMessage = "Showing all encoding jobs."
        }
    }

    func clearJobStateFilter() {
        guard jobStateFilter != nil else { return }
        jobStateFilter = nil
        statusMessage = "Showing all encoding jobs."
    }

    func isInputFormatEnabled(_ format: InputAudioFormat) -> Bool {
        format.fileExtensions.isSubset(of: selectedInputExtensions)
    }

    func isInputFormatEnabled(_ format: InputVideoFormat) -> Bool {
        format.fileExtensions.isSubset(of: selectedVideoInputExtensions)
    }

    func isMediaCopyExtensionEnabled(_ fileExtension: String) -> Bool {
        currentMediaCopySelectedExtensions.contains(fileExtension.lowercased())
    }

    func setMediaCopyExtension(_ fileExtension: String, enabled: Bool) {
        guard !isMediaCopyBusy else { return }
        let normalizedExtension = fileExtension.lowercased()
        guard mediaCopyFilter.fileExtensions.contains(normalizedExtension) else { return }

        switch mediaCopyFilter {
        case .all:
            return
        case .audio:
            if enabled {
                mediaCopyAudioExtensions.insert(normalizedExtension)
            } else {
                mediaCopyAudioExtensions.remove(normalizedExtension)
            }
        case .video:
            if enabled {
                mediaCopyVideoExtensions.insert(normalizedExtension)
            } else {
                mediaCopyVideoExtensions.remove(normalizedExtension)
            }
        }
        if fileManagementMode == .copy {
            statusMessage = "File Management filter set to \(mediaCopyDeleteSummary)."
        }
    }

    func selectAllMediaCopyExtensions() {
        guard !isMediaCopyBusy, mediaCopyFilter.supportsExtensionSelection else { return }
        switch mediaCopyFilter {
        case .all:
            return
        case .audio:
            mediaCopyAudioExtensions = MediaFileFilter.audio.fileExtensions
        case .video:
            mediaCopyVideoExtensions = MediaFileFilter.video.fileExtensions
        }
        if fileManagementMode == .copy {
            statusMessage = "Selected all \(mediaCopyFilter.title.lowercased()) extensions."
        }
    }

    func deselectAllMediaCopyExtensions() {
        guard !isMediaCopyBusy, mediaCopyFilter.supportsExtensionSelection else { return }
        switch mediaCopyFilter {
        case .all:
            return
        case .audio:
            mediaCopyAudioExtensions.removeAll()
        case .video:
            mediaCopyVideoExtensions.removeAll()
        }
        if fileManagementMode == .copy {
            statusMessage = "Deselected all \(mediaCopyFilter.title.lowercased()) extensions."
        }
    }

    func selectAllInputFormats() {
        guard !isEncoding else { return }
        switch encodingWorkflow {
        case .audio:
            selectedInputExtensions = AudioFormat.inputExtensions
        case .video:
            selectedVideoInputExtensions = VideoFormat.inputExtensions
        }
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = activeFilterStatusMessage
    }

    func deselectAllInputFormats() {
        guard !isEncoding else { return }
        switch encodingWorkflow {
        case .audio:
            selectedInputExtensions.removeAll()
        case .video:
            selectedVideoInputExtensions.removeAll()
        }
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = activeFilterStatusMessage
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Use Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = exportFolder ?? lastInputDirectoryURL()

        guard panel.runModal() == .OK else { return }
        exportFolder = panel.url
        outputMode = .exportFolder
        statusMessage = "Export folder set to \(panel.url?.path(percentEncoded: false) ?? "")."
    }

    func removeInput(_ item: AudioInputItem) {
        guard !isEncoding else { return }
        inputs.removeAll { $0.id == item.id }
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = inputs.isEmpty ? "Queue cleared." : "Removed \(item.name)."
    }

    func trashInputSource(_ item: AudioInputItem) {
        guard !isEncoding else { return }

        let alert = NSAlert()
        alert.messageText = "Move source file to Trash?"
        alert.informativeText =
            "This will move \(item.name) to the macOS Trash and remove it from the queue."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pendingRecord: PendingTrashSourceRecord
        do {
            pendingRecord = try recordPendingTrashIntent(for: item)
        } catch {
            statusMessage =
                "Could not save emergency trash journal. Nothing moved to Trash: \(error.localizedDescription)"
            return
        }

        do {
            let result = try moveItemToTrashAndRecord(
                TrashableFileItem(audioInput: item),
                pendingRecord: pendingRecord
            )
            inputs.removeAll { $0.id == item.id }
            jobs.removeAll()
            jobStateFilter = nil
            if result == .restoreLedgerRecorded {
                try? removePendingTrashRecords(ids: [pendingRecord.id])
                statusMessage = "Moved \(item.name) to Trash. Restore record saved."
            } else {
                statusMessage =
                    "Moved \(item.name) to Trash. macOS did not return a Trash path, so the original path remains in the emergency journal."
            }
        } catch {
            removePendingTrashRecordIfOriginalStillExists(pendingRecord)
            statusMessage = "Could not move \(item.name) to Trash: \(error.localizedDescription)"
        }
    }

    func trashAllInputSources() {
        let itemsToTrash = queueItemsForActions
        guard !isEncoding, !itemsToTrash.isEmpty else { return }

        let count = itemsToTrash.count
        let hiddenCount = inputs.count - count
        let alert = NSAlert()
        alert.messageText =
            jobStateFilter == nil ? "Move active source files to Trash?" : "Move filtered source files to Trash?"
        var details =
            "This will move \(count) \(jobStateFilter == nil ? "active" : "filtered") source file\(count == 1 ? "" : "s") to the macOS Trash and remove successful items from the queue."
        if hiddenCount > 0 {
            details +=
                " \(hiddenCount) queued file\(hiddenCount == 1 ? "" : "s") outside this action will stay untouched."
        }
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.addButton(withTitle: jobStateFilter == nil ? "Move Active to Trash" : "Move Filtered to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pendingRecordsByItemID: [UUID: PendingTrashSourceRecord]
        do {
            pendingRecordsByItemID = try recordPendingTrashIntents(for: itemsToTrash)
        } catch {
            statusMessage =
                "Could not save emergency trash journal. Nothing moved to Trash: \(error.localizedDescription)"
            return
        }

        var trashedIDs = Set<UUID>()
        var failures: [String] = []
        var emergencyOnly: [String] = []

        for item in itemsToTrash {
            guard let pendingRecord = pendingRecordsByItemID[item.id] else {
                failures.append(item.name)
                continue
            }

            do {
                let result = try moveItemToTrashAndRecord(
                    TrashableFileItem(audioInput: item),
                    pendingRecord: pendingRecord
                )
                trashedIDs.insert(item.id)
                if result == .restoreLedgerRecorded {
                    try? removePendingTrashRecords(ids: [pendingRecord.id])
                } else {
                    emergencyOnly.append(item.name)
                }
            } catch {
                removePendingTrashRecordIfOriginalStillExists(pendingRecord)
                failures.append(item.name)
            }
        }

        inputs.removeAll { trashedIDs.contains($0.id) }
        jobs.removeAll()
        jobStateFilter = nil

        var resultDetails = [
            "Moved \(trashedIDs.count) source file\(trashedIDs.count == 1 ? "" : "s") to Trash."
        ]
        if !emergencyOnly.isEmpty {
            resultDetails.append(
                "\(emergencyOnly.count) path\(emergencyOnly.count == 1 ? "" : "s") kept in the emergency journal because macOS did not return a Trash path."
            )
        }
        if !failures.isEmpty {
            resultDetails.append(
                "Could not move \(failures.count): \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? "..." : "")."
            )
        }
        statusMessage = resultDetails.joined(separator: " ")
    }

    func restoreTrashedSources() {
        guard canRestoreTrashedSources else { return }

        let count = trashedSourceRecords.count
        let alert = NSAlert()
        alert.messageText = "Restore trashed files?"
        alert.informativeText =
            "GPhilCoder will move \(count) recorded Trash item\(count == 1 ? "" : "s") back to their original folder when the Trash item still exists and the original path is free."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var restored: [TrashedSourceRecord] = []
        var unavailable: [TrashedSourceRecord] = []
        var conflicts: [TrashedSourceRecord] = []
        var failures: [String] = []

        for record in trashedSourceRecords {
            let trashURL = URL(fileURLWithPath: record.trashPath)
            let originalURL = URL(fileURLWithPath: record.originalPath)

            guard regularFileExists(atPath: trashURL.path) else {
                unavailable.append(record)
                continue
            }

            guard !FileManager.default.fileExists(atPath: originalURL.path) else {
                conflicts.append(record)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: trashURL, to: originalURL)
                restored.append(record)
                appendRestoredInput(from: record, restoredURL: originalURL)
            } catch {
                failures.append(record.name)
            }
        }

        let removableIDs = Set((restored + unavailable).map(\.id))
        trashedSourceRecords.removeAll { removableIDs.contains($0.id) }
        jobs.removeAll()
        jobStateFilter = nil

        var details = [
            "Restored \(restored.count) file\(restored.count == 1 ? "" : "s")."
        ]
        if !unavailable.isEmpty {
            details.append(
                "\(unavailable.count) stale restore record\(unavailable.count == 1 ? "" : "s") removed because the Trash item no longer exists."
            )
        }
        if !conflicts.isEmpty {
            details.append(
                "\(conflicts.count) original path conflict\(conflicts.count == 1 ? "" : "s") skipped."
            )
        }
        if !failures.isEmpty {
            details.append(
                "Could not restore \(failures.count): \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? "..." : "")."
            )
        }
        statusMessage = details.joined(separator: " ")
    }

    func clearTrashedSourceRecords() {
        guard canClearTrashedSourceRecords else { return }

        let count = trashedSourceRecords.count
        let alert = NSAlert()
        alert.messageText = "Clear restore records?"
        alert.informativeText =
            "This only removes GPhilCoder's saved restore list for \(count) trashed file\(count == 1 ? "" : "s"). It does not delete or restore any files."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Records")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        trashedSourceRecords.removeAll()
        statusMessage =
            "Cleared \(count) saved restore record\(count == 1 ? "" : "s"). No files were changed."
    }

    func chooseRestoreDeletedFolder() {
        if let url = chooseDirectory(
            title: "Choose Deleted Files Folder",
            prompt: "Use Deleted Folder",
            initialURL: restoreDeletedFolder ?? lastInputDirectoryURL()
        ) {
            restoreDeletedFolder = url
        }
    }

    func chooseRestoreBackupRoot() {
        if let url = chooseDirectory(
            title: "Choose Backup Root",
            prompt: "Use Backup Root",
            initialURL: restoreBackupRoot
        ) {
            restoreBackupRoot = url
        }
    }

    func chooseRestoreDestinationRoot() {
        if let url = chooseDirectory(
            title: "Choose Restore Root",
            prompt: "Use Restore Root",
            initialURL: restoreDestinationRoot
        ) {
            restoreDestinationRoot = url
        }
    }

    func chooseMediaCopySourceRoot() {
        guard !isMediaCopyBusy else { return }
        if let urls = chooseDirectories(
            title: "Choose Source Folders",
            prompt: "Use Sources",
            initialURL: primaryMediaCopySourceRoot ?? lastInputDirectoryURL()
        ) {
            mediaCopySourceRoots = urls
            rememberInputDirectory(urls.first)
            if fileManagementMode == .copy {
                statusMessage =
                    "Media copy source set to \(urls.count) folder\(urls.count == 1 ? "" : "s")."
            }
        }
    }

    func chooseMediaCopyDestinationRoot() {
        guard !isMediaCopyBusy else { return }
        if let url = chooseDirectory(
            title: "Choose Destination Folder",
            prompt: "Use Destination",
            initialURL: mediaCopyDestinationRoot ?? primaryMediaCopySourceRoot ?? lastInputDirectoryURL()
        ) {
            mediaCopyDestinationRoot = url
            statusMessage = "Media copy destination set to \(url.path(percentEncoded: false))."
        }
    }

    func scanMediaCopyFiles() {
        runMediaCopyPreflight(copyAfterScan: false)
    }

    func copyFilteredMediaFiles() {
        runMediaCopyPreflight(copyAfterScan: true)
    }

    func deleteFilteredMediaFiles() {
        runFilteredMediaTrash()
    }

    func renameFilteredMediaFiles() {
        runFilteredMediaRename()
    }

    func undoLastMediaRename() {
        runMediaRenameHistoryAction(.undo)
    }

    func redoLastMediaRename() {
        runMediaRenameHistoryAction(.redo)
    }

    func addCurrentMediaCopyWorkflowToQueue() {
        guard let destinationRoot = mediaCopyDestinationRoot,
            canAddMediaCopyWorkflowToQueue
        else {
            statusMessage = "Choose source and destination folders before adding to the queue."
            return
        }

        for sourceRoot in mediaCopySourceRoots {
            guard validateMediaCopyFolders(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
            else {
                return
            }
        }

        let workflows = mediaCopySourceRoots.map {
            MediaCopyWorkflow(
                sourceRoot: $0,
                destinationRoot: destinationRoot,
                filter: mediaCopyFilter,
                selectedExtensions: selectedExtensions(for: mediaCopyFilter),
                fileNameFilter: currentMediaFileNameFilter
            )
        }
        mediaCopyQueue.append(contentsOf: workflows)
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        statusMessage =
            "Added \(workflows.count) workflow\(workflows.count == 1 ? "" : "s") to the file copy queue."
    }

    func removeMediaCopyWorkflowFromQueue(_ workflow: MediaCopyWorkflow) {
        guard !isMediaCopyBusy else { return }
        mediaCopyQueue.removeAll { $0.id == workflow.id }
        statusMessage =
            mediaCopyQueue.isEmpty
            ? "File copy queue cleared."
            : "Removed queued workflow. \(mediaCopyQueue.count) remaining."
    }

    func clearMediaCopyQueue() {
        guard !isMediaCopyBusy else { return }
        mediaCopyQueue.removeAll()
        currentMediaCopyWorkflowID = nil
        statusMessage = "File copy queue cleared."
    }

    func saveMediaCopyJob() {
        guard canSaveMediaCopyJob else {
            statusMessage = "Add workflows to the file copy queue before saving a job."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save File Copy Job"
        panel.prompt = "Save Job"
        panel.allowedContentTypes = [MediaCopyJobFile.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = mediaCopyDestinationRoot ?? primaryMediaCopySourceRoot ?? lastInputDirectoryURL()
        panel.nameFieldStringValue = defaultMediaCopyJobFileName()

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let url = normalizedMediaCopyJobFileURL(selectedURL)
        let document = MediaCopyJobDocument(workflows: mediaCopyQueue)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved file copy job with \(mediaCopyQueue.count) workflow\(mediaCopyQueue.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not save file copy job: \(error.localizedDescription)"
        }
    }

    func loadMediaCopyJob() {
        guard !isMediaCopyBusy else { return }

        let panel = NSOpenPanel()
        panel.title = "Load File Copy Job"
        panel.prompt = "Load Job"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [MediaCopyJobFile.contentType, .json]
        panel.directoryURL = mediaCopyDestinationRoot ?? primaryMediaCopySourceRoot ?? lastInputDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(MediaCopyJobDocument.self, from: data)
            let workflows = document.workflows.filter {
                directoryURLIfExists(atPath: $0.sourceRoot.path) != nil
                    && directoryURLIfExists(atPath: $0.destinationRoot.path) != nil
            }
            mediaCopyQueue = workflows
            mediaCopyPlan = nil
            mediaCopyProgress = nil
            currentMediaCopyWorkflowID = nil

            var details = [
                "Loaded \(workflows.count) file copy workflow\(workflows.count == 1 ? "" : "s")."
            ]
            let skipped = document.workflows.count - workflows.count
            if skipped > 0 {
                details.append("Skipped \(skipped) workflow\(skipped == 1 ? "" : "s") with missing folders.")
            }
            statusMessage = details.joined(separator: " ")
        } catch {
            statusMessage = "Could not load file copy job: \(error.localizedDescription)"
        }
    }

    func runMediaCopyQueue() {
        guard canRunMediaCopyQueue else { return }

        for workflow in mediaCopyQueue {
            guard validateMediaCopyFolders(
                sourceRoot: workflow.sourceRoot,
                destinationRoot: workflow.destinationRootPreservingSourceFolder
            ) else {
                return
            }
        }

        runQueuedMediaCopyWorkflows(mediaCopyQueue)
    }

    func cancelMediaCopy() {
        guard isMediaCopyBusy else { return }
        mediaCopyTask?.cancel()
        mediaCopyTask = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        mediaRenameProgressVerb = "renamed"
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        statusMessage = "File management operation cancelled."
    }

    func buildBackupRestorePlan() {
        guard canBuildBackupRestorePlan,
            let deletedFolder = restoreDeletedFolder,
            let backupRoot = restoreBackupRoot,
            let restoreRoot = restoreDestinationRoot
        else {
            statusMessage = "Choose deleted, backup, and restore folders before building a plan."
            return
        }

        restorePlanTask?.cancel()
        restorePlanRecords.removeAll()
        restorePlanScanSummary = nil
        restorePlanLiveCounts = RestorePlanStatusCounts()
        restorePlanLiveUnresolvedItems.removeAll()
        restorePlanStoppedWithPartialResults = false
        restorePlanProgress = RestorePlanProgress(
            phase: .scanningDeleted,
            completed: 0,
            total: nil,
            detail: "Preparing deleted-folder scan."
        )
        isRestorePlanning = true
        statusMessage = "Scanning deleted files and checking the restore root..."

        let options = RestorePlanOptions(
            deletedFolder: deletedFolder,
            backupRoot: backupRoot,
            restoreRoot: restoreRoot,
            matchMode: restoreMatchMode,
            hashMode: restoreHashMode,
            includeHidden: restoreIncludeHidden
        )
        let progressHandler: RestorePlanProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.isRestorePlanning == true else { return }
                self?.restorePlanProgress = progress
                if let statusCounts = progress.statusCounts {
                    self?.restorePlanLiveCounts = statusCounts
                }
                if let unresolvedItems = progress.unresolvedItems {
                    self?.restorePlanLiveUnresolvedItems = unresolvedItems
                }
                self?.statusMessage = "\(progress.title): \(progress.detail)"
            }
        }

        restorePlanTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try RestorePlanner.buildPlan(options: options, progress: progressHandler)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                let records = result.records
                self?.restorePlanRecords = records
                self?.restorePlanLiveCounts = nil
                self?.restorePlanLiveUnresolvedItems.removeAll()
                self?.restorePlanScanSummary = result.scanSummary
                self?.restorePlanProgress = nil
                self?.isRestorePlanning = false
                self?.restorePlanStoppedWithPartialResults = false
                self?.restorePlanTask = nil
                self?.statusMessage =
                    "Restore plan built: \(records.filter { $0.status == .alreadyRestored }.count) restored, \(records.filter { $0.status == .matched }.count) backup matches, \(records.filter { $0.status == .matchedConflict }.count) target exists, \(records.filter { $0.status == .ambiguous }.count) ambiguous, \(records.filter { $0.status == .missing }.count) missing."
            } catch {
                guard !Task.isCancelled else { return }
                self?.restorePlanRecords.removeAll()
                self?.restorePlanLiveCounts = nil
                self?.restorePlanLiveUnresolvedItems.removeAll()
                self?.restorePlanScanSummary = nil
                self?.restorePlanProgress = nil
                self?.isRestorePlanning = false
                self?.restorePlanStoppedWithPartialResults = false
                self?.restorePlanTask = nil
                self?.statusMessage = "Could not build restore plan: \(error.localizedDescription)"
            }
        }
    }

    func applyBackupRestorePlan() {
        guard canApplyBackupRestorePlan else { return }

        let count = restorePlanRestorableCount
        let alert = NSAlert()
        alert.messageText = "Restore matched files?"
        alert.informativeText =
            "GPhilCoder will copy \(count) matched file\(count == 1 ? "" : "s") to the restore root using \(restoreCopySource.title.lowercased()). Existing restore paths are \(restoreOverwriteExisting ? "overwritten" : "skipped")."
        alert.alertStyle = restoreOverwriteExisting ? .warning : .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreApplyTask?.cancel()
        restorePlanProgress = nil
        isRestoringFromPlan = true
        statusMessage = "Restoring matched files..."
        let records = restorePlanRecords
        let copySource = restoreCopySource
        let overwrite = restoreOverwriteExisting

        restoreApplyTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                RestorePlanner.apply(records: records, copySource: copySource, overwrite: overwrite)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }

            self?.appendRestoredFileURLs(result.restoredURLs)
            self?.isRestoringFromPlan = false
            self?.restoreApplyTask = nil

            var details = [
                "Restored \(result.copied) file\(result.copied == 1 ? "" : "s")."
            ]
            if result.skipped > 0 {
                details.append("Skipped \(result.skipped).")
            }
            if result.failed > 0 {
                details.append(
                    "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
                )
            }
            self?.statusMessage = details.joined(separator: " ")
        }
    }

    func cancelBackupRestorePlan() {
        restorePlanTask?.cancel()
        restorePlanTask = nil
        isRestorePlanning = false
        restorePlanStoppedWithPartialResults = true

        let unresolvedCount = restorePlanLiveUnresolvedItems.count
        if unresolvedCount > 0 {
            statusMessage =
                "Stopped restore search. Kept partial snapshot with \(unresolvedCount) unresolved file\(unresolvedCount == 1 ? "" : "s")."
        } else if let counts = restorePlanLiveCounts, counts.deletedTotal > 0 {
            statusMessage = "Stopped restore search. Kept partial counters: \(counts.summary)"
        } else {
            statusMessage = "Stopped restore search before an unresolved snapshot was available."
        }
    }

    func exportRestoreUnresolvedItems() {
        let items = restoreUnresolvedExportItems
        guard !items.isEmpty else {
            statusMessage = "No unresolved files to export yet."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Unresolved Files"
        panel.prompt = "Export JSON"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = restoreDeletedFolder ?? lastInputDirectoryURL()
        panel.nameFieldStringValue = defaultRestoreUnresolvedFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document = RestoreUnresolvedExportDocument(
            version: 1,
            exportedAt: Date(),
            isPartialSearchSnapshot: isRestorePlanning || restorePlanStoppedWithPartialResults,
            deletedFolderPath: restoreDeletedFolder?.path(percentEncoded: false),
            backupRootPath: restoreBackupRoot?.path(percentEncoded: false),
            restoreRootPath: restoreDestinationRoot?.path(percentEncoded: false),
            matchMode: restoreMatchMode.title,
            hashMode: restoreHashMode.title,
            progressPhase: restorePlanProgress?.title,
            progressDetail: restorePlanProgress?.detail,
            deletedCount: restorePlanDeletedCount,
            restoredCount: restorePlanAlreadyRestoredCount,
            unresolvedListCount: items.count,
            files: items
        )

        let exportURL = normalizedJSONFileURL(url)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: exportURL, options: .atomic)
            statusMessage =
                "Exported \(items.count) unresolved file\(items.count == 1 ? "" : "s") to \(exportURL.lastPathComponent)."
        } catch {
            statusMessage = "Could not export unresolved files: \(error.localizedDescription)"
        }
    }

    func copyRestoreUnresolvedItemsToRestoreRoot() {
        let items = restoreUnresolvedExportItems
        guard let restoreRoot = restoreDestinationRoot, !items.isEmpty else {
            statusMessage = "No unresolved files to copy."
            return
        }

        let destinationFolder = restoreRoot.appendingPathComponent(
            "GPhilCoder Unresolved Files",
            isDirectory: true
        )

        let alert = NSAlert()
        alert.messageText = "Copy unresolved files to the restore root?"
        alert.informativeText =
            "GPhilCoder will copy \(items.count) unresolved file\(items.count == 1 ? "" : "s") into \(destinationFolder.path(percentEncoded: false)). Original subfolders are still unknown, so this creates a holding folder and does not overwrite existing files."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreApplyTask?.cancel()
        isRestoringFromPlan = true
        statusMessage = "Copying unresolved files to the restore root..."

        restoreApplyTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.copyUnresolvedItems(items, to: destinationFolder)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }

            self?.appendRestoredFileURLs(result.copiedURLs)
            self?.isRestoringFromPlan = false
            self?.restoreApplyTask = nil

            var details = [
                "Copied \(result.copied) unresolved file\(result.copied == 1 ? "" : "s") to GPhilCoder Unresolved Files."
            ]
            if result.failed > 0 {
                details.append(
                    "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
                )
            }
            self?.statusMessage = details.joined(separator: " ")
        }
    }

    func refreshMediaDeletePreview() {
        scanMediaFileInventoryThenRefresh(.delete)
    }

    func refreshMediaRenamePreview() {
        scanMediaFileInventoryThenRefresh(.rename)
    }

    private func refreshActiveFileManagementPreviewIfNeeded() {
        refreshMediaDeletePreviewIfNeeded()
        refreshMediaRenamePreviewIfNeeded()
    }

    private func refreshMediaDeletePreviewIfNeeded() {
        guard fileManagementMode == .delete else { return }

        guard !mediaCopySourceRoots.isEmpty, mediaCopyHasSelectedExtensionsForCurrentFilter else {
            mediaDeletePlan = nil
            return
        }

        if mediaFileInventoryMatchesCurrentSources {
            rebuildMediaDeletePreviewFromInventory()
        } else {
            scanMediaFileInventoryThenRefresh(.delete)
        }
    }

    private func refreshMediaRenamePreviewIfNeeded() {
        guard fileManagementMode == .rename else { return }

        guard !mediaCopySourceRoots.isEmpty, mediaCopyHasSelectedExtensionsForCurrentFilter else {
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            return
        }

        if mediaFileInventoryMatchesCurrentSources {
            rebuildMediaRenamePreviewFromInventory()
        } else {
            scanMediaFileInventoryThenRefresh(.rename)
        }
    }

    private func scanMediaFileInventoryThenRefresh(_ targetMode: FileManagementMode) {
        guard targetMode == .delete || targetMode == .rename else { return }
        guard !mediaCopySourceRoots.isEmpty, !isMediaCopyBusy else { return }
        if targetMode == .delete {
            guard mediaCopyHasSelectedExtensionsForCurrentFilter else {
                mediaDeletePlan = nil
                return
            }
        } else {
            guard mediaCopyHasSelectedExtensionsForCurrentFilter else {
                mediaRenamePlan = nil
                isMediaRenamePreviewStale = false
                return
            }
        }

        let sourceRoots = mediaCopySourceRoots

        mediaCopyTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = true
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        statusMessage =
            "Scanning \(sourceRoots.count) source folder\(sourceRoots.count == 1 ? "" : "s") into memory..."

        mediaCopyTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try MediaCopyPlanner.scanFileInventory(sourceRoots: sourceRoots)
                }
                let inventory = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }

                guard let self else { return }

                self.mediaFileInventory = inventory
                self.mediaFileInventorySourceRootPaths = sourceRoots.map {
                    $0.standardizedFileURL.path
                }
                self.isMediaCopyScanning = false
                self.mediaCopyTask = nil

                guard self.fileManagementMode == targetMode else {
                    self.refreshActiveFileManagementPreviewIfNeeded()
                    return
                }

                switch targetMode {
                case .delete:
                    self.rebuildMediaDeletePreviewFromInventory()
                case .rename:
                    self.rebuildMediaRenamePreviewFromInventory()
                case .copy:
                    break
                }
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.isMediaCopyScanning = false
                self?.mediaCopyTask = nil
                self?.statusMessage = "File inventory scan cancelled."
            } catch {
                guard !Task.isCancelled else { return }
                self?.mediaFileInventory = []
                self?.mediaFileInventorySourceRootPaths = []
                if targetMode == .delete {
                    self?.mediaDeletePlan = nil
                } else {
                    self?.mediaRenamePlan = nil
                    self?.isMediaRenamePreviewStale = false
                }
                self?.mediaCopyProgress = nil
                self?.isMediaCopyScanning = false
                self?.mediaCopyTask = nil
                self?.statusMessage =
                    "Could not scan source folders: \(error.localizedDescription)"
            }
        }
    }

    private func rebuildMediaDeletePreviewFromInventory() {
        guard mediaFileInventoryMatchesCurrentSources else {
            scanMediaFileInventoryThenRefresh(.delete)
            return
        }

        let plan = MediaCopyPlanner.buildDeletePlan(
            sourceRoots: mediaCopySourceRoots,
            filter: mediaCopyFilter,
            selectedExtensions: currentMediaCopySelectedExtensions,
            fileNameFilter: currentMediaFileNameFilter,
            candidateLimit: Self.mediaPreviewLimit,
            inventory: mediaFileInventory
        )
        mediaCopyPlan = nil
        mediaDeletePlan = plan
        mediaRenamePlan = nil
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        statusMessage = Self.mediaDeleteScanStatusMessage(for: plan)
    }

    private func rebuildMediaRenamePreviewFromInventory() {
        guard mediaFileInventoryMatchesCurrentSources else {
            scanMediaFileInventoryThenRefresh(.rename)
            return
        }

        let filter = mediaCopyFilter
        let plan = MediaCopyPlanner.buildRenamePlan(
            sourceRoots: mediaCopySourceRoots,
            filter: filter,
            selectedExtensions: selectedExtensions(for: filter),
            fileNameFilter: currentMediaFileNameFilter,
            itemLimit: Self.mediaPreviewLimit,
            settings: currentMediaRenameSettings(),
            inventory: mediaFileInventory
        )
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = plan
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        statusMessage = Self.mediaRenameScanStatusMessage(for: plan)
    }

    private func runMediaCopyPreflight(copyAfterScan: Bool) {
        guard let sourceRoot = primaryMediaCopySourceRoot,
            let destinationRoot = mediaCopyDestinationRoot
        else {
            statusMessage = "Choose source and destination folders before copying media files."
            return
        }

        guard validateMediaCopyFolders(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        else {
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = nil
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        isMediaCopyScanning = true
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false

        let filter = mediaCopyFilter
        let selectedExtensions = selectedExtensions(for: filter)
        let fileNameFilter = currentMediaFileNameFilter
        let candidateLimit = copyAfterScan ? nil : Self.mediaPreviewLimit
        statusMessage =
            "Scanning \(filter.fileTypeName) files in \(sourceRoot.lastPathComponent)..."

        mediaCopyTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try MediaCopyPlanner.buildPlan(
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot,
                        filter: filter,
                        selectedExtensions: selectedExtensions,
                        fileNameFilter: fileNameFilter,
                        candidateLimit: candidateLimit
                    )
                }
                let plan = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }

                self?.mediaCopyPlan = plan
                self?.isMediaCopyScanning = false

                guard copyAfterScan else {
                    self?.statusMessage = Self.mediaCopyScanStatusMessage(for: plan)
                    self?.mediaCopyTask = nil
                    return
                }

                guard plan.hasCopyableContent else {
                    let completionMessage =
                        "No \(filter.fileTypeName) files found in \(sourceRoot.lastPathComponent)."
                    self?.statusMessage = completionMessage
                    AppNotifier.notifyIfAppInactive(
                        title: "File copy finished",
                        body: completionMessage
                    )
                    self?.mediaCopyTask = nil
                    return
                }

                guard let resolution = self?.promptMediaCopyConflictResolution(for: [plan]) else {
                    self?.statusMessage = "Media copy cancelled."
                    self?.mediaCopyTask = nil
                    return
                }

                self?.isMediaCopying = true
                let progressStartedAt = Date()
                self?.mediaCopyProgress = MediaCopyProgress(
                    completed: 0,
                    total: plan.candidates.count,
                    copied: 0,
                    skippedExisting: 0,
                    failed: 0,
                    copiedBytes: 0,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: progressStartedAt,
                    updatedAt: progressStartedAt,
                    currentName: nil
                )
                self?.statusMessage =
                    "Copying \(plan.candidates.count) \(filter.fileTypeName) file\(plan.candidates.count == 1 ? "" : "s")..."

                let result = await self?.copyMediaCopyPlan(plan, conflictResolution: resolution)
                    ?? MediaCopyResult(total: plan.candidates.count, cancelled: true)

                guard !Task.isCancelled else { return }

                self?.isMediaCopying = false
                self?.mediaCopyTask = nil
                let completionMessage = Self.mediaCopyResultStatusMessage(
                    result,
                    filter: filter,
                    destinationRoot: destinationRoot
                )
                self?.statusMessage = completionMessage
                AppNotifier.notifyIfAppInactive(
                    title: "File copy finished",
                    body: completionMessage
                )
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.isMediaCopyScanning = false
                self?.isMediaCopying = false
                self?.mediaCopyTask = nil
                self?.statusMessage = "Media copy cancelled."
            } catch {
                guard !Task.isCancelled else { return }
                self?.mediaCopyPlan = nil
                self?.mediaCopyProgress = nil
                self?.isMediaCopyScanning = false
                self?.isMediaCopying = false
                self?.mediaCopyTask = nil
                self?.statusMessage = "Could not prepare media copy: \(error.localizedDescription)"
            }
        }
    }

    private func runFilteredMediaTrash() {
        guard fileManagementMode == .delete else { return }

        guard let plan = mediaDeletePlan, plan.hasDeletableContent else {
            statusMessage = "No filtered delete preview is ready yet."
            refreshMediaDeletePreviewIfNeeded()
            return
        }

        guard currentMediaDeletePlanMatchesFilters else {
            statusMessage = "Refresh the delete preview before moving files to Trash."
            refreshMediaDeletePreviewIfNeeded()
            return
        }

        let fullPlan = MediaCopyPlanner.buildDeletePlan(
            sourceRoots: plan.sourceRoots,
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter,
            inventory: mediaFileInventory
        )
        guard fullPlan.hasDeletableContent else {
            statusMessage = "No filtered files are available to move to Trash."
            mediaDeletePlan = fullPlan
            return
        }

        let items = fullPlan.candidates.map { TrashableFileItem(deleteCandidate: $0) }
        guard confirmFilteredMediaTrash(
            itemCount: items.count,
            totalSize: fullPlan.totalSizeBytes,
            sourceRootCount: fullPlan.sourceRoots.count,
            filter: fullPlan.filter,
            selectedExtensions: fullPlan.selectedExtensions,
            fileNameFilter: fullPlan.fileNameFilter
        ) else {
            statusMessage = "Filtered delete cancelled."
            return
        }

        let pendingRecordsByItemID: [UUID: PendingTrashSourceRecord]
        do {
            pendingRecordsByItemID = try recordPendingTrashIntents(for: items)
        } catch {
            statusMessage =
                "Could not save emergency trash journal. Nothing moved to Trash: \(error.localizedDescription)"
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = true
        let progressStartedAt = Date()
        mediaCopyProgress = MediaCopyProgress(
            completed: 0,
            total: items.count,
            copied: 0,
            skippedExisting: 0,
            failed: 0,
            copiedBytes: 0,
            totalBytes: fullPlan.totalSizeBytes,
            startedAt: progressStartedAt,
            updatedAt: progressStartedAt,
            currentName: nil
        )
        statusMessage =
            "Moving \(items.count) filtered file\(items.count == 1 ? "" : "s") to Trash..."

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await moveTrashableItemsToTrash(
                items,
                pendingRecordsByItemID: pendingRecordsByItemID
            )

            guard !Task.isCancelled else { return }

            isMediaDeleting = false
            mediaCopyTask = nil
            let completionMessage = Self.mediaTrashResultStatusMessage(
                result,
                filter: fullPlan.filter,
                selectedExtensions: fullPlan.selectedExtensions,
                fileNameFilter: fullPlan.fileNameFilter
            )
            statusMessage = completionMessage
            AppNotifier.notifyIfAppInactive(
                title: "Filtered delete finished",
                body: completionMessage
            )
        }
    }

    private func runFilteredMediaRename() {
        guard fileManagementMode == .rename else { return }

        guard let plan = mediaRenamePlan else {
            statusMessage = "No rename preview is ready yet."
            refreshMediaRenamePreviewIfNeeded()
            return
        }

        guard !isMediaRenamePreviewStale else {
            statusMessage = "Refresh the rename preview before applying these settings."
            return
        }

        let fullPlan = MediaCopyPlanner.buildRenamePlan(
            sourceRoots: plan.sourceRoots,
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter,
            settings: plan.settings,
            inventory: mediaFileInventory
        )

        guard fullPlan.blockedCount == 0 else {
            statusMessage =
                "Resolve \(fullPlan.blockedCount) rename conflict\(fullPlan.blockedCount == 1 ? "" : "s") before applying."
            mediaRenamePlan = fullPlan
            return
        }

        let items = fullPlan.readyItems
        guard !items.isEmpty else {
            statusMessage = "No files need renaming."
            mediaRenamePlan = fullPlan
            return
        }

        guard confirmMediaRename(itemCount: items.count, unchangedCount: fullPlan.unchangedCount) else {
            statusMessage = "Rename cancelled."
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = true
        mediaRenameProgressVerb = "renamed"
        let progressStartedAt = Date()
        mediaCopyProgress = MediaCopyProgress(
            completed: 0,
            total: items.count,
            copied: 0,
            skippedExisting: fullPlan.unchangedCount,
            failed: 0,
            copiedBytes: 0,
            totalBytes: fullPlan.totalSizeBytes,
            startedAt: progressStartedAt,
            updatedAt: progressStartedAt,
            currentName: nil
        )
        statusMessage =
            "Renaming \(items.count) file\(items.count == 1 ? "" : "s")..."

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await renameMediaItems(items, unchangedCount: fullPlan.unchangedCount)

            guard !Task.isCancelled else { return }

            isMediaRenaming = false
            mediaCopyTask = nil
            if !result.historyItems.isEmpty {
                pushMediaRenameUndoTransaction(
                    MediaRenameHistoryTransaction(
                        actionTitle: plan.settings.operation.title,
                        items: result.historyItems
                    )
                )
                mediaRenameRedoStack.removeAll()
            }
            let completionMessage = Self.mediaRenameResultStatusMessage(result)
            statusMessage = completionMessage
            AppNotifier.notifyIfAppInactive(
                title: "Rename finished",
                body: completionMessage
            )
        }
    }

    private func runMediaRenameHistoryAction(_ direction: MediaRenameHistoryDirection) {
        guard fileManagementMode == .rename else { return }

        let transaction: MediaRenameHistoryTransaction?
        switch direction {
        case .undo:
            transaction = mediaRenameUndoStack.last
        case .redo:
            transaction = mediaRenameRedoStack.last
        }

        guard let transaction, !transaction.items.isEmpty else {
            statusMessage = "No rename action to \(direction == .undo ? "undo" : "redo")."
            return
        }

        guard confirmMediaRenameHistoryAction(transaction, direction: direction) else {
            statusMessage = "\(direction.title) cancelled."
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = true
        mediaRenameProgressVerb = direction.progressVerb
        let progressStartedAt = Date()
        mediaCopyProgress = MediaCopyProgress(
            completed: 0,
            total: transaction.items.count,
            copied: 0,
            skippedExisting: 0,
            failed: 0,
            copiedBytes: 0,
            totalBytes: transaction.items.reduce(Int64(0)) { $0 + $1.fileSizeBytes },
            startedAt: progressStartedAt,
            updatedAt: progressStartedAt,
            currentName: nil
        )
        statusMessage =
            "\(direction.progressTitle) for \(transaction.items.count) file\(transaction.items.count == 1 ? "" : "s")..."

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await applyMediaRenameHistoryTransaction(
                transaction,
                direction: direction
            )

            guard !Task.isCancelled else { return }

            isMediaRenaming = false
            mediaCopyTask = nil
            completeMediaRenameHistoryAction(
                transaction,
                direction: direction,
                result: result
            )
            moveMediaInventoryRecords(result.movedItems, direction: direction)
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            let completionMessage = Self.mediaRenameHistoryResultStatusMessage(
                result,
                direction: direction
            )
            statusMessage = completionMessage
            AppNotifier.notifyIfAppInactive(
                title: direction.notificationTitle,
                body: completionMessage
            )
        }
    }

    private func runQueuedMediaCopyWorkflows(_ workflows: [MediaCopyWorkflow]) {
        mediaCopyTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = true
        isMediaCopying = false
        statusMessage =
            "Scanning \(workflows.count) queued file copy workflow\(workflows.count == 1 ? "" : "s")..."

        mediaCopyTask = Task { [weak self] in
            do {
                var workflowPlans: [(workflow: MediaCopyWorkflow, plan: MediaCopyPlan)] = []

                for (index, workflow) in workflows.enumerated() {
                    guard !Task.isCancelled else { return }
                    self?.currentMediaCopyWorkflowID = workflow.id
                    self?.statusMessage =
                        "Scanning queued workflow \(index + 1) of \(workflows.count)..."

                    let worker = Task.detached(priority: .userInitiated) {
                        try MediaCopyPlanner.buildPlan(
                            sourceRoot: workflow.sourceRoot,
                            destinationRoot: workflow.destinationRootPreservingSourceFolder,
                            filter: workflow.filter,
                            selectedExtensions: workflow.selectedExtensions,
                            fileNameFilter: workflow.fileNameFilter
                        )
                    }
                    let plan = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    workflowPlans.append((workflow, plan))
                }

                guard !Task.isCancelled else { return }

                self?.isMediaCopyScanning = false

                let nonEmptyWorkflowPlans = workflowPlans.filter(\.plan.hasCopyableContent)
                guard !nonEmptyWorkflowPlans.isEmpty else {
                    let completionMessage = "No files found in the queued file copy workflows."
                    self?.currentMediaCopyWorkflowID = nil
                    self?.mediaCopyTask = nil
                    self?.statusMessage = completionMessage
                    AppNotifier.notifyIfAppInactive(
                        title: "File copy queue finished",
                        body: completionMessage
                    )
                    return
                }

                let nonEmptyPlans = nonEmptyWorkflowPlans.map(\.plan)
                guard let resolution = self?.promptMediaCopyConflictResolution(for: nonEmptyPlans) else {
                    self?.currentMediaCopyWorkflowID = nil
                    self?.mediaCopyTask = nil
                    self?.statusMessage = "File copy queue cancelled."
                    return
                }

                self?.isMediaCopying = true
                self?.statusMessage =
                    "Copying \(nonEmptyWorkflowPlans.count) queued workflow\(nonEmptyWorkflowPlans.count == 1 ? "" : "s")..."

                var aggregateResult = MediaCopyResult(
                    total: nonEmptyPlans.reduce(0) { $0 + $1.candidates.count }
                )

                for workflowPlan in nonEmptyWorkflowPlans {
                    guard !Task.isCancelled else {
                        aggregateResult.cancelled = true
                        break
                    }

                    self?.currentMediaCopyWorkflowID = workflowPlan.workflow.id
                    self?.mediaCopyPlan = workflowPlan.plan
                    let result = await self?.copyMediaCopyPlan(
                        workflowPlan.plan,
                        conflictResolution: resolution
                    ) ?? MediaCopyResult(
                        total: workflowPlan.plan.candidates.count,
                        cancelled: true
                    )

                    aggregateResult.copied += result.copied
                    aggregateResult.skippedExisting += result.skippedExisting
                    aggregateResult.failed += result.failed
                    aggregateResult.failedNames.append(contentsOf: result.failedNames)
                    aggregateResult.createdDirectories += result.createdDirectories
                    aggregateResult.failedDirectories += result.failedDirectories
                    aggregateResult.failedDirectoryNames.append(
                        contentsOf: result.failedDirectoryNames
                    )
                    aggregateResult.cancelled = aggregateResult.cancelled || result.cancelled
                }

                guard !Task.isCancelled else { return }

                self?.isMediaCopying = false
                self?.currentMediaCopyWorkflowID = nil
                self?.mediaCopyTask = nil
                let completionMessage = Self.mediaCopyQueueResultStatusMessage(
                    aggregateResult,
                    workflowCount: nonEmptyWorkflowPlans.count
                )
                self?.statusMessage = completionMessage
                AppNotifier.notifyIfAppInactive(
                    title: "File copy queue finished",
                    body: completionMessage
                )
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.isMediaCopyScanning = false
                self?.isMediaCopying = false
                self?.currentMediaCopyWorkflowID = nil
                self?.mediaCopyTask = nil
                self?.statusMessage = "File copy queue cancelled."
            } catch {
                guard !Task.isCancelled else { return }
                self?.mediaCopyProgress = nil
                self?.isMediaCopyScanning = false
                self?.isMediaCopying = false
                self?.currentMediaCopyWorkflowID = nil
                self?.mediaCopyTask = nil
                self?.statusMessage = "Could not run file copy queue: \(error.localizedDescription)"
            }
        }
    }

    private func copyMediaCopyPlan(
        _ plan: MediaCopyPlan,
        conflictResolution: MediaCopyConflictResolution
    ) async -> MediaCopyResult {
        var result = MediaCopyResult(total: plan.candidates.count)
        let progressStartedAt = Date()
        let totalBytes = plan.totalSizeBytes
        var copiedBytes: Int64 = 0

        if !plan.relativeDirectories.isEmpty {
            let failedDirectories = await Task.detached(priority: .userInitiated) {
                MediaCopyPlanner.createDirectories(for: plan)
            }.value
            result.failedDirectories = failedDirectories.count
            result.failedDirectoryNames = failedDirectories
            result.createdDirectories = plan.relativeDirectories.count - failedDirectories.count
        }

        for (index, candidate) in plan.candidates.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index,
                total: plan.candidates.count,
                copied: result.copied,
                skippedExisting: result.skippedExisting,
                failed: result.failed,
                copiedBytes: copiedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: candidate.name
            )

            let itemResult = await Task.detached(priority: .userInitiated) {
                MediaCopyPlanner.copyCandidate(
                    candidate,
                    conflictResolution: conflictResolution
                )
            }.value

            switch itemResult {
            case .copied:
                result.copied += 1
                copiedBytes += candidate.fileSizeBytes
            case .skippedExisting:
                result.skippedExisting += 1
            case .failed(let name):
                result.failed += 1
                result.failedNames.append(name)
            }

            let progressUpdatedAt = Date()
            mediaCopyProgress = MediaCopyProgress(
                completed: index + 1,
                total: plan.candidates.count,
                copied: result.copied,
                skippedExisting: result.skippedExisting,
                failed: result.failed,
                copiedBytes: copiedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: progressUpdatedAt,
                currentName: candidate.name
            )
            let speedDetail = mediaCopyProgress?.bytesPerSecond
                .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
            statusMessage =
                "Copied \(result.copied), skipped \(result.skippedExisting), failed \(result.failed) of \(plan.candidates.count)\(speedDetail)."
        }

        return result
    }

    private func moveTrashableItemsToTrash(
        _ items: [TrashableFileItem],
        pendingRecordsByItemID: [UUID: PendingTrashSourceRecord]
    ) async -> MediaTrashResult {
        var result = MediaTrashResult(total: items.count)
        let progressStartedAt = Date()
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var movedBytes: Int64 = 0
        var movedPaths = Set<String>()

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index,
                total: items.count,
                copied: result.moved,
                skippedExisting: 0,
                failed: result.failed,
                copiedBytes: movedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: item.name
            )

            guard let pendingRecord = pendingRecordsByItemID[item.id] else {
                result.failed += 1
                result.failedNames.append(item.name)
                continue
            }

            do {
                let moveResult = try moveItemToTrashAndRecord(item, pendingRecord: pendingRecord)
                result.moved += 1
                movedBytes += item.fileSizeBytes
                movedPaths.insert(item.url.standardizedFileURL.path)
                if moveResult == .restoreLedgerRecorded {
                    try? removePendingTrashRecords(ids: [pendingRecord.id])
                } else {
                    result.emergencyOnly += 1
                }
            } catch {
                removePendingTrashRecordIfOriginalStillExists(pendingRecord)
                result.failed += 1
                result.failedNames.append(item.name)
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index + 1,
                total: items.count,
                copied: result.moved,
                skippedExisting: 0,
                failed: result.failed,
                copiedBytes: movedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: item.name
            )
            let speedDetail = mediaCopyProgress?.bytesPerSecond
                .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
            statusMessage =
                "Moved \(result.moved), failed \(result.failed) of \(items.count) to Trash\(speedDetail)."
        }

        if !movedPaths.isEmpty {
            inputs.removeAll { movedPaths.contains($0.url.standardizedFileURL.path) }
            removeMediaInventoryRecords(matching: movedPaths)
            if let mediaDeletePlan {
                self.mediaDeletePlan = MediaDeletePlan(
                    sourceRoots: mediaDeletePlan.sourceRoots,
                    filter: mediaDeletePlan.filter,
                    selectedExtensions: mediaDeletePlan.selectedExtensions,
                    fileNameFilter: mediaDeletePlan.fileNameFilter,
                    candidates: mediaDeletePlan.candidates.filter {
                        !movedPaths.contains($0.sourceURL.standardizedFileURL.path)
                    },
                    candidateCount: max(0, mediaDeletePlan.candidateCount - movedPaths.count),
                    totalSizeBytes: max(0, mediaDeletePlan.totalSizeBytes - movedBytes),
                    scannedAt: Date()
                )
            }
            jobs.removeAll()
            jobStateFilter = nil
        }

        return result
    }

    private func renameMediaItems(
        _ items: [MediaRenameItem],
        unchangedCount: Int
    ) async -> MediaRenameResult {
        var result = MediaRenameResult(total: items.count)
        let progressStartedAt = Date()
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var renamedBytes: Int64 = 0
        var renamedSourcePaths = Set<String>()

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index,
                total: items.count,
                copied: result.renamed,
                skippedExisting: unchangedCount,
                failed: result.failed,
                copiedBytes: renamedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: item.originalName
            )

            let renameSucceeded = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.renameMediaItem(item)
                    return true
                } catch {
                    return false
                }
            }.value

            if renameSucceeded {
                result.renamed += 1
                renamedBytes += item.fileSizeBytes
                renamedSourcePaths.insert(item.sourceURL.standardizedFileURL.path)
                result.historyItems.append(
                    MediaRenameHistoryItem(
                        originalPath: item.sourceURL.standardizedFileURL.path,
                        renamedPath: item.targetURL.standardizedFileURL.path,
                        originalName: item.originalName,
                        renamedName: item.newName,
                        fileSizeBytes: item.fileSizeBytes
                    )
                )
            } else {
                result.failed += 1
                result.failedNames.append(item.originalName)
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index + 1,
                total: items.count,
                copied: result.renamed,
                skippedExisting: unchangedCount,
                failed: result.failed,
                copiedBytes: renamedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: item.originalName
            )
            statusMessage =
                "Renamed \(result.renamed), failed \(result.failed) of \(items.count)."
        }

        if !renamedSourcePaths.isEmpty {
            moveMediaInventoryRecords(result.historyItems, direction: .redo)
            if let mediaRenamePlan {
                let remainingItems = mediaRenamePlan.items.filter {
                    !renamedSourcePaths.contains($0.sourceURL.standardizedFileURL.path)
                }
                self.mediaRenamePlan = MediaRenamePlan(
                    sourceRoots: mediaRenamePlan.sourceRoots,
                    filter: mediaRenamePlan.filter,
                    selectedExtensions: mediaRenamePlan.selectedExtensions,
                    fileNameFilter: mediaRenamePlan.fileNameFilter,
                    settings: mediaRenamePlan.settings,
                    items: remainingItems,
                    itemCount: max(0, mediaRenamePlan.itemCount - renamedSourcePaths.count),
                    totalSizeBytes: max(0, mediaRenamePlan.totalSizeBytes - renamedBytes),
                    readyCount: remainingItems.filter { $0.state == .ready }.count,
                    blockedCount: mediaRenamePlan.blockedCount,
                    unchangedCount: mediaRenamePlan.unchangedCount,
                    scannedAt: Date()
                )
            }
            jobs.removeAll()
            jobStateFilter = nil
        }

        return result
    }

    private func applyMediaRenameHistoryTransaction(
        _ transaction: MediaRenameHistoryTransaction,
        direction: MediaRenameHistoryDirection
    ) async -> MediaRenameHistoryResult {
        var result = MediaRenameHistoryResult(total: transaction.items.count)
        let progressStartedAt = Date()
        let totalBytes = transaction.items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var movedBytes: Int64 = 0

        for (index, item) in transaction.items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            let sourceURL: URL
            let targetURL: URL
            let currentName: String
            switch direction {
            case .undo:
                sourceURL = URL(fileURLWithPath: item.renamedPath)
                targetURL = URL(fileURLWithPath: item.originalPath)
                currentName = item.renamedName
            case .redo:
                sourceURL = URL(fileURLWithPath: item.originalPath)
                targetURL = URL(fileURLWithPath: item.renamedPath)
                currentName = item.originalName
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index,
                total: transaction.items.count,
                copied: result.moved,
                skippedExisting: 0,
                failed: result.failed,
                copiedBytes: movedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: currentName
            )

            let moveSucceeded = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.moveRenameFile(from: sourceURL, to: targetURL)
                    return true
                } catch {
                    return false
                }
            }.value

            if moveSucceeded {
                result.moved += 1
                movedBytes += item.fileSizeBytes
                result.movedItems.append(item)
            } else {
                result.failed += 1
                result.failedNames.append(currentName)
            }

            mediaCopyProgress = MediaCopyProgress(
                completed: index + 1,
                total: transaction.items.count,
                copied: result.moved,
                skippedExisting: 0,
                failed: result.failed,
                copiedBytes: movedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: currentName
            )
            statusMessage =
                "\(direction.progressTitle): \(result.moved) \(direction.progressVerb), \(result.failed) failed of \(transaction.items.count)."
        }

        if result.moved > 0 {
            jobs.removeAll()
            jobStateFilter = nil
        }

        return result
    }

    private func completeMediaRenameHistoryAction(
        _ transaction: MediaRenameHistoryTransaction,
        direction: MediaRenameHistoryDirection,
        result: MediaRenameHistoryResult
    ) {
        let movedIDs = Set(result.movedItems.map(\.id))
        let remainingItems = transaction.items.filter { !movedIDs.contains($0.id) }

        switch direction {
        case .undo:
            removeMediaRenameTransaction(transaction, fromUndoStack: true)
            if !remainingItems.isEmpty {
                pushMediaRenameUndoTransaction(transaction.replacingItems(remainingItems))
            }
            if !result.movedItems.isEmpty {
                pushMediaRenameRedoTransaction(transaction.replacingItems(result.movedItems))
            }
        case .redo:
            removeMediaRenameTransaction(transaction, fromUndoStack: false)
            if !remainingItems.isEmpty {
                pushMediaRenameRedoTransaction(transaction.replacingItems(remainingItems))
            }
            if !result.movedItems.isEmpty {
                pushMediaRenameUndoTransaction(transaction.replacingItems(result.movedItems))
            }
        }
    }

    private func pushMediaRenameUndoTransaction(_ transaction: MediaRenameHistoryTransaction) {
        guard !transaction.items.isEmpty else { return }
        mediaRenameUndoStack.append(transaction)
        if mediaRenameUndoStack.count > Self.mediaRenameHistoryLimit {
            mediaRenameUndoStack.removeFirst(mediaRenameUndoStack.count - Self.mediaRenameHistoryLimit)
        }
    }

    private func pushMediaRenameRedoTransaction(_ transaction: MediaRenameHistoryTransaction) {
        guard !transaction.items.isEmpty else { return }
        mediaRenameRedoStack.append(transaction)
        if mediaRenameRedoStack.count > Self.mediaRenameHistoryLimit {
            mediaRenameRedoStack.removeFirst(mediaRenameRedoStack.count - Self.mediaRenameHistoryLimit)
        }
    }

    private func removeMediaRenameTransaction(
        _ transaction: MediaRenameHistoryTransaction,
        fromUndoStack: Bool
    ) {
        if fromUndoStack {
            if mediaRenameUndoStack.last?.id == transaction.id {
                mediaRenameUndoStack.removeLast()
            } else {
                mediaRenameUndoStack.removeAll { $0.id == transaction.id }
            }
        } else if mediaRenameRedoStack.last?.id == transaction.id {
            mediaRenameRedoStack.removeLast()
        } else {
            mediaRenameRedoStack.removeAll { $0.id == transaction.id }
        }
    }

    private func removeMediaInventoryRecords(matching paths: Set<String>) {
        guard !paths.isEmpty else { return }
        mediaFileInventory.removeAll {
            paths.contains($0.sourceURL.standardizedFileURL.path)
        }
    }

    private func moveMediaInventoryRecords(
        _ items: [MediaRenameHistoryItem],
        direction: MediaRenameHistoryDirection
    ) {
        guard !items.isEmpty, !mediaFileInventory.isEmpty else { return }

        for item in items {
            let sourcePath: String
            let targetPath: String
            switch direction {
            case .undo:
                sourcePath = item.renamedPath
                targetPath = item.originalPath
            case .redo:
                sourcePath = item.originalPath
                targetPath = item.renamedPath
            }

            guard let index = mediaFileInventory.firstIndex(where: {
                $0.sourceURL.standardizedFileURL.path == sourcePath
            }) else {
                continue
            }

            let record = mediaFileInventory[index]
            let targetURL = URL(fileURLWithPath: targetPath)
            let relativePath: String
            if let relativeDirectory = record.relativeDirectory {
                relativePath = "\(relativeDirectory)/\(targetURL.lastPathComponent)"
            } else {
                relativePath = targetURL.lastPathComponent
            }

            mediaFileInventory[index] = MediaFileInventoryRecord(
                id: targetURL.standardizedFileURL.path,
                sourceURL: targetURL,
                sourceRoot: record.sourceRoot,
                relativePath: relativePath,
                fileSizeBytes: record.fileSizeBytes,
                modifiedDate: record.modifiedDate
            )
        }

        mediaFileInventory.sort {
            $0.sourceURL.path.localizedCaseInsensitiveCompare($1.sourceURL.path)
                == .orderedAscending
        }
    }

    nonisolated private static func renameMediaItem(_ item: MediaRenameItem) throws {
        try moveRenameFile(from: item.sourceURL, to: item.targetURL)
    }

    nonisolated private static func moveRenameFile(from sourceURL: URL, to targetURL: URL) throws {
        let fileManager = FileManager.default
        let sourcePath = sourceURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        let sourceKey = sourcePath.lowercased()
        let targetKey = targetPath.lowercased()

        if sourceKey == targetKey && sourcePath != targetPath {
            let temporaryURL = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(".gphilcoder-rename-\(UUID().uuidString).tmp")
            try fileManager.moveItem(at: sourceURL, to: temporaryURL)
            do {
                try fileManager.moveItem(at: temporaryURL, to: targetURL)
            } catch {
                try? fileManager.moveItem(at: temporaryURL, to: sourceURL)
                throw error
            }
            return
        }

        guard !fileManager.fileExists(atPath: targetPath) else {
            throw CocoaError(.fileWriteFileExists)
        }

        try fileManager.moveItem(at: sourceURL, to: targetURL)
    }

    private func confirmMediaRename(itemCount: Int, unchangedCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rename filtered files?"
        var detail =
            "GPhilCoder will rename \(itemCount) file\(itemCount == 1 ? "" : "s") in place. Extensions are preserved."
        if unchangedCount > 0 {
            detail += " \(unchangedCount) unchanged file\(unchangedCount == 1 ? "" : "s") will be skipped."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmMediaRenameHistoryAction(
        _ transaction: MediaRenameHistoryTransaction,
        direction: MediaRenameHistoryDirection
    ) -> Bool {
        let count = transaction.items.count
        let alert = NSAlert()
        alert.messageText = "\(direction.title)?"
        switch direction {
        case .undo:
            alert.informativeText =
                "GPhilCoder will move \(count) renamed file\(count == 1 ? "" : "s") back to their previous name. Files are skipped if the renamed source is missing or the previous name is already taken."
        case .redo:
            alert.informativeText =
                "GPhilCoder will reapply \(count) previously undone rename\(count == 1 ? "" : "s"). Files are skipped if the original source is missing or the renamed target is already taken."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: direction == .undo ? "Undo" : "Redo")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmFilteredMediaTrash(
        itemCount: Int,
        totalSize: Int64,
        sourceRootCount: Int,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move filtered files to Trash?"
        let scopeDescription = Self.mediaDeleteScopeDescription(
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter
        )
        let untouchedDescription = filter.supportsExtensionSelection
            ? " Other file extensions stay untouched."
            : ""
        alert.informativeText =
            "GPhilCoder will move \(itemCount) file\(itemCount == 1 ? "" : "s") matching \(scopeDescription) to the macOS Trash from \(sourceRootCount) selected source folder\(sourceRootCount == 1 ? "" : "s").\(untouchedDescription) Restore records will be saved so these files can be moved back when the Trash items are still available. Total size: \(totalSize.formattedFileSize)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptMediaCopyConflictResolution(
        for plans: [MediaCopyPlan]
    ) -> MediaCopyConflictResolution? {
        let conflictCount = plans.reduce(0) { $0 + $1.conflictCount }
        guard conflictCount > 0 else { return .skipExisting }
        let candidateCount = plans.reduce(0) { $0 + $1.candidates.count }
        let destinationDescription =
            plans.count == 1
            ? plans[0].destinationRoot.path(percentEncoded: false)
            : "\(plans.count) queued destinations"
        let fileTypeName =
            Set(plans.map(\.filter)).count == 1
            ? plans[0].filter.fileTypeName
            : "queued"

        let alert = NSAlert()
        alert.messageText = "Existing files found in the destination"
        alert.informativeText =
            "\(conflictCount) of \(candidateCount) matching \(fileTypeName) file\(conflictCount == 1 ? "" : "s") already exist under \(destinationDescription). Choose whether to skip those files or replace them. Other destination files are not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Skip Existing")
        alert.addButton(withTitle: "Replace Existing")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .skipExisting
        case .alertSecondButtonReturn:
            return .replaceExisting
        default:
            return nil
        }
    }

    nonisolated private static func mediaTrashResultStatusMessage(
        _ result: MediaTrashResult,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter
    ) -> String {
        if result.cancelled {
            return "Filtered delete cancelled after \(result.moved) moved file\(result.moved == 1 ? "" : "s")."
        }

        var details = [
            "Moved \(result.moved) file\(result.moved == 1 ? "" : "s") matching \(mediaDeleteScopeDescription(filter: filter, selectedExtensions: selectedExtensions, fileNameFilter: fileNameFilter)) to Trash."
        ]
        if result.emergencyOnly > 0 {
            details.append(
                "\(result.emergencyOnly) restore path\(result.emergencyOnly == 1 ? "" : "s") kept in the emergency journal because macOS did not return a Trash path."
            )
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    nonisolated private static func copyUnresolvedItems(
        _ items: [RestoreUnresolvedFile],
        to destinationFolder: URL
    ) -> RestoreUnresolvedCopyResult {
        var result = RestoreUnresolvedCopyResult()
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
        } catch {
            result.failed = items.count
            result.failedNames = Array(items.prefix(3).map(\.name))
            return result
        }

        for item in items {
            guard !Task.isCancelled else { break }

            let sourceURL = URL(fileURLWithPath: item.deletedPath)
            let preferredName = item.matchName ?? item.name
            let destinationURL = availableDestinationURL(
                in: destinationFolder,
                preferredName: preferredName
            )

            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                result.copied += 1
                result.copiedURLs.append(destinationURL)
            } catch {
                result.failed += 1
                result.failedNames.append(item.name)
            }
        }

        return result
    }

    nonisolated private static func availableDestinationURL(
        in folder: URL,
        preferredName: String
    ) -> URL {
        let fileManager = FileManager.default
        let preferredURL = folder.appendingPathComponent(preferredName, isDirectory: false)
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let baseName = (preferredName as NSString).deletingPathExtension
        let fileExtension = (preferredName as NSString).pathExtension

        for index in 2...10_000 {
            let candidateName =
                fileExtension.isEmpty
                ? "\(baseName) \(index)"
                : "\(baseName) \(index).\(fileExtension)"
            let candidateURL = folder.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folder.appendingPathComponent(UUID().uuidString + "-" + preferredName)
    }

    func clearInputs() {
        guard !isEncoding else { return }
        inputs.removeAll()
        jobs.removeAll()
        jobStateFilter = nil
        statusMessage = "Queue cleared."
    }

    func saveQueue() {
        guard !isEncoding else { return }
        let itemsToSave = queueItemsForActions
        guard !itemsToSave.isEmpty else {
            statusMessage = "Add files before saving a queue."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Queue"
        panel.prompt = "Save Queue"
        panel.allowedContentTypes = [QueueFile.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = lastInputDirectoryURL()
        panel.nameFieldStringValue = defaultQueueFileName()

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let url = normalizedQueueFileURL(selectedURL)
        let document = QueueDocument(
            version: QueueDocument.currentVersion,
            savedAt: Date(),
            settings: currentQueueSettings(),
            items: itemsToSave.map { queueInput(from: $0) }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved queue with \(itemsToSave.count) item\(itemsToSave.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not save queue: \(error.localizedDescription)"
        }
    }

    func loadQueue() {
        guard !isEncoding else { return }

        let panel = NSOpenPanel()
        panel.title = "Load Queue"
        panel.prompt = "Load Queue"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [QueueFile.contentType, QueueFile.legacyContentType, .json]
        panel.directoryURL = lastInputDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(QueueDocument.self, from: data)
            let settingsWarning = applyQueueSettings(document.settings)
            let result = loadInputs(from: document.items)

            inputs = result.items
            jobs.removeAll()
            jobStateFilter = nil
            rememberInputDirectory(fromFiles: result.items.map(\.url))

            var details = [
                "Loaded \(result.items.count) queued item\(result.items.count == 1 ? "" : "s")."
            ]
            if result.missing > 0 {
                details.append(
                    "Skipped \(result.missing) missing file\(result.missing == 1 ? "" : "s").")
            }
            if result.unsupported > 0 {
                details.append(
                    "Skipped \(result.unsupported) unsupported item\(result.unsupported == 1 ? "" : "s")."
                )
            }
            if result.duplicates > 0 {
                details.append(
                    "Ignored \(result.duplicates) duplicate\(result.duplicates == 1 ? "" : "s").")
            }
            if settingsWarning {
                details.append(
                    "Export folder was unavailable, so output was set to source folders.")
            }

            statusMessage = details.joined(separator: " ")
        } catch {
            statusMessage = "Could not load queue: \(error.localizedDescription)"
        }
    }

    func revealOutput(for job: EncodeJob) {
        let urls = existingOutputURLs(for: job.outputURL)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [job.outputURL] : urls)
    }

    func startEncoding() {
        guard canEncode, let selectedFFmpegURL = encodingFFmpegURL else { return }

        if encodingWorkflow == .audio, outputFormat == .ogg, oggMode == .bitrate, !supportsOggBitrate {
            statusMessage = FFmpegToolError.unsupportedOggBitrate.localizedDescription
            return
        }

        if encodingWorkflow == .video, !supportsHEVCVideoToolbox {
            statusMessage =
                "This FFmpeg build does not include hevc_videotoolbox, so Apple Silicon HEVC encoding is unavailable."
            return
        }

        let itemsToEncode = activeInputs
        guard !itemsToEncode.isEmpty else {
            statusMessage = "No queued files match the selected input filters."
            return
        }

        let plannedJobs = itemsToEncode.map {
            EncodeJob(item: $0, outputURL: outputURL(for: $0))
        }
        let settings = EncodingSettingsSnapshot(
            ffmpegURL: selectedFFmpegURL,
            useLibVorbis: ffmpegCapabilities.hasLibVorbis,
            encodingWorkflow: encodingWorkflow,
            outputFormat: outputFormat,
            videoOutputContainer: videoOutputContainer,
            hevcPreset: hevcPreset,
            customVideoBitrateKbps: customVideoBitrateKbps,
            videoScaleMode: videoScaleMode,
            videoAudioMode: videoAudioMode,
            videoHardwareDecodeMode: videoHardwareDecodeMode,
            mp3Mode: mp3Mode,
            vbrQuality: vbrQuality,
            cbrBitrateKbps: cbrBitrateKbps,
            abrBitrateKbps: abrBitrateKbps,
            oggMode: oggMode,
            oggQuality: oggQuality,
            oggBitrateKbps: oggBitrateKbps,
            opusRateMode: opusRateMode,
            opusBitrateKbps: opusBitrateKbps,
            flacCompressionLevel: flacCompressionLevel,
            splitOversizedMultichannel: splitOversizedMultichannel,
            ffmpegThreads: ffmpegThreads,
            overwriteExisting: overwriteExisting,
            parallelJobs: max(1, min(parallelJobs, processorLimit))
        )

        guard confirmEncodingPreflight(plannedJobs: plannedJobs, settings: settings) else {
            statusMessage = "Encoding cancelled before starting."
            return
        }

        jobs = plannedJobs
        jobStateFilter = nil
        isEncoding = true

        statusMessage =
            "Encoding \(plannedJobs.count) \(plannedJobs.count == 1 ? "file" : "files") with \(settings.summary)..."

        encodeTask = Task { [weak self] in
            await self?.runJobs(settings: settings)
        }
    }

    func cancelEncoding() {
        encodeTask?.cancel()
        statusMessage = "Stopping active encoding jobs..."
    }

    func refreshCurrentFileManagementPreview() {
        refreshActiveFileManagementPreviewIfNeeded()
    }

    private func confirmEncodingPreflight(
        plannedJobs: [EncodeJob],
        settings: EncodingSettingsSnapshot
    ) -> Bool {
        let existingOutputCount = plannedJobs.filter {
            !existingOutputURLs(for: $0.outputURL).isEmpty
        }.count
        let routeDescription: String
        switch outputMode {
        case .sourceFolders:
            routeDescription = "Outputs will be written beside each source file."
        case .exportFolder:
            if let exportFolder {
                let subfolderDetail = preserveSubfolders ? " Nested folders will be preserved." : ""
                routeDescription =
                    "Outputs will be written to \(exportFolder.path(percentEncoded: false)).\(subfolderDetail)"
            } else {
                routeDescription = "No export folder is selected."
            }
        }

        var details = [
            "\(plannedJobs.count) file\(plannedJobs.count == 1 ? "" : "s") will be encoded as \(outputFormatTitle).",
            routeDescription,
            "Encoding settings: \(settings.summary).",
            "Parallel jobs: \(settings.parallelJobs); FFmpeg threads: \(settings.ffmpegThreads == 0 ? "Auto" : "\(settings.ffmpegThreads)")."
        ]

        if existingOutputCount > 0 {
            let conflictBehavior =
                overwriteExisting
                ? "They will be replaced."
                : "They will be skipped unless overwrite is enabled."
            details.append(
                "\(existingOutputCount) output path\(existingOutputCount == 1 ? "" : "s") already exist. \(conflictBehavior)"
            )
        }

        if let sameFormatWarningMessage {
            details.append(sameFormatWarningMessage)
        }

        if let lossyToLosslessWarningMessage {
            details.append(lossyToLosslessWarningMessage)
        }

        if let nativeOggReencodeWarningMessage {
            details.append(nativeOggReencodeWarningMessage)
        }

        let alert = NSAlert()
        alert.messageText = "Start encoding?"
        alert.informativeText = details.joined(separator: "\n\n")
        alert.alertStyle = existingOutputCount > 0 && overwriteExisting ? .warning : .informational
        alert.addButton(withTitle: "Start Encoding")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func defaultQueueFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhilCoder Queue \(formatter.string(from: Date())).\(QueueFile.fileExtension)"
    }

    private func defaultMediaCopyJobFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhilCoder File Copy \(formatter.string(from: Date())).\(MediaCopyJobFile.fileExtension)"
    }

    private func defaultRestoreUnresolvedFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhilCoder Unresolved \(formatter.string(from: Date())).json"
    }

    private func normalizedQueueFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(QueueFile.fileExtension) : url
    }

    private func normalizedMediaCopyJobFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(MediaCopyJobFile.fileExtension) : url
    }

    private func normalizedJSONFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension("json") : url
    }

    private func existingOutputURLs(for baseOutputURL: URL) -> [URL] {
        if FileManager.default.fileExists(atPath: baseOutputURL.path) {
            return [baseOutputURL]
        }

        let directory = baseOutputURL.deletingLastPathComponent()
        let baseName = baseOutputURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseOutputURL.pathExtension.lowercased()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter {
                $0.deletingPathExtension().lastPathComponent.hasPrefix(baseName + "_ch")
                    && $0.pathExtension.lowercased() == fileExtension
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    private func currentQueueSettings() -> QueueSettings {
        QueueSettings(
            encodingWorkflow: encodingWorkflow.rawValue,
            outputMode: outputMode.rawValue,
            exportFolderPath: exportFolder?.standardizedFileURL.path(percentEncoded: false),
            selectedInputExtensions: selectedInputExtensions.sorted(),
            selectedVideoInputExtensions: selectedVideoInputExtensions.sorted(),
            preserveSubfolders: preserveSubfolders,
            overwriteExisting: overwriteExisting,
            outputFormat: outputFormat.rawValue,
            videoOutputContainer: videoOutputContainer.rawValue,
            hevcPreset: hevcPreset.rawValue,
            customVideoBitrateKbps: customVideoBitrateKbps,
            videoScaleMode: videoScaleMode.rawValue,
            videoAudioMode: videoAudioMode.rawValue,
            videoHardwareDecodeMode: videoHardwareDecodeMode.rawValue,
            mp3Mode: mp3Mode.rawValue,
            vbrQuality: vbrQuality,
            cbrBitrateKbps: cbrBitrateKbps,
            abrBitrateKbps: abrBitrateKbps,
            oggMode: oggMode.rawValue,
            oggQuality: oggQuality,
            oggBitrateKbps: oggBitrateKbps,
            opusRateMode: opusRateMode.rawValue,
            opusBitrateKbps: opusBitrateKbps,
            flacCompressionLevel: flacCompressionLevel,
            splitOversizedMultichannel: splitOversizedMultichannel,
            parallelJobs: max(1, min(parallelJobs, processorLimit)),
            ffmpegThreads: max(0, min(ffmpegThreads, processorLimit))
        )
    }

    private func currentEncodingPreset(
        id: UUID = UUID(),
        named name: String,
        createdAt: Date = Date()
    ) -> EncodingPreset {
        let now = Date()
        switch encodingWorkflow {
        case .audio:
            return EncodingPreset(
                id: id,
                name: name,
                workflow: .audio,
                audio: makeAudioPresetSettings(),
                createdAt: createdAt,
                updatedAt: now
            )
        case .video:
            return EncodingPreset(
                id: id,
                name: name,
                workflow: .video,
                video: makeVideoPresetSettings(),
                createdAt: createdAt,
                updatedAt: now
            )
        }
    }

    private func makeAudioPresetSettings() -> AudioEncodingPresetSettings {
        AudioEncodingPresetSettings(
            outputFormat: outputFormat,
            mp3Mode: mp3Mode,
            vbrQuality: vbrQuality,
            cbrBitrateKbps: cbrBitrateKbps,
            abrBitrateKbps: abrBitrateKbps,
            oggMode: oggMode,
            oggQuality: oggQuality,
            oggBitrateKbps: oggBitrateKbps,
            opusRateMode: opusRateMode,
            opusBitrateKbps: opusBitrateKbps,
            flacCompressionLevel: flacCompressionLevel,
            splitOversizedMultichannel: splitOversizedMultichannel
        )
    }

    private func makeVideoPresetSettings() -> VideoEncodingPresetSettings {
        VideoEncodingPresetSettings(
            outputContainer: videoOutputContainer,
            hevcPreset: hevcPreset,
            customBitrateKbps: customVideoBitrateKbps,
            scaleMode: videoScaleMode,
            audioMode: videoAudioMode,
            hardwareDecodeMode: videoHardwareDecodeMode
        )
    }

    private func applyEncodingPreset(_ preset: EncodingPreset) {
        guard !isEncoding else { return }

        // Guard against silently dropping a populated queue when loading a preset
        // of a different workflow. The workflow assignment below would otherwise
        // trigger encodingWorkflow.didSet, which clears jobs unconditionally.
        if preset.workflow != encodingWorkflow, !jobs.isEmpty {
            guard confirmSwitchWorkflow(target: preset.workflow, queuedCount: jobs.count) else {
                statusMessage = "Load cancelled."
                return
            }
        }

        // Warn before loading a preset the active FFmpeg can't actually encode.
        // Mirrors the capability checks that gate startEncoding().
        if let reason = unsupportedEncoderReason(for: preset) {
            guard confirmLoadWithUnsupportedEncoder(reason) else {
                statusMessage = "Load cancelled."
                return
            }
        }

        encodingWorkflow = preset.workflow
        switch preset.workflow {
        case .audio:
            guard let audio = preset.audio else {
                statusMessage = "Preset \(preset.name) has no audio settings."
                return
            }
            outputFormat = audio.outputFormat
            mp3Mode = audio.mp3Mode
            vbrQuality = audio.vbrQuality
            cbrBitrateKbps = audio.cbrBitrateKbps
            abrBitrateKbps = audio.abrBitrateKbps
            oggMode = audio.oggMode
            oggQuality = audio.oggQuality
            oggBitrateKbps = audio.oggBitrateKbps
            opusRateMode = audio.opusRateMode
            opusBitrateKbps = audio.opusBitrateKbps
            flacCompressionLevel = audio.flacCompressionLevel
            splitOversizedMultichannel = audio.splitOversizedMultichannel
            selectedAudioEncodingPresetID = preset.id
        case .video:
            guard let video = preset.video else {
                statusMessage = "Preset \(preset.name) has no video settings."
                return
            }
            videoOutputContainer = video.outputContainer
            hevcPreset = video.hevcPreset
            customVideoBitrateKbps = max(500, min(video.customBitrateKbps, 100_000))
            videoScaleMode = video.scaleMode
            videoAudioMode = video.audioMode
            videoHardwareDecodeMode = video.hardwareDecodeMode
            selectedVideoEncodingPresetID = preset.id
        }

        statusMessage = "Loaded \(preset.workflow.title.lowercased()) preset \(preset.name)."
    }

    private func defaultEncodingPresetName() -> String {
        switch encodingWorkflow {
        case .audio:
            return currentEncodingPreset(named: "Preset").summary
        case .video:
            return hevcPreset.title + " " + videoOutputContainer.title
        }
    }

    private func promptEncodingPresetName(
        title: String,
        message: String,
        defaultName: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = defaultName
        textField.selectText(nil)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func confirmDeleteEncodingPreset(_ preset: EncodingPreset) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete encoding preset?"
        alert.informativeText = "This will delete \(preset.name)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSwitchWorkflow(
        target: EncodingWorkflow,
        queuedCount: Int
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Switch to \(target.title)?"
        alert.informativeText =
            "Switching to the \(target.title.lowercased()) workflow will remove \(queuedCount) queued \(encodingWorkflow.queueNoun)\(queuedCount == 1 ? "" : "s") from the current queue."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmLoadWithUnsupportedEncoder(_ reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Load this preset anyway?"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Load Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The user-facing reason a preset can't be encoded with the active FFmpeg,
    /// or nil if it is encodable. Mirrors the capability checks in startEncoding().
    private func unsupportedEncoderReason(for preset: EncodingPreset) -> String? {
        switch preset.workflow {
        case .audio:
            if let audio = preset.audio,
                audio.outputFormat == .ogg,
                audio.oggMode == .bitrate,
                !supportsOggBitrate
            {
                return "This FFmpeg build lacks libvorbis, so the preset's Ogg bitrate mode may fail. Load it anyway?"
            }
            return nil
        case .video:
            if !supportsHEVCVideoToolbox {
                return "This FFmpeg build does not include hevc_videotoolbox, so HEVC video encoding is unavailable. Load it anyway?"
            }
            return nil
        }
    }

    private func queueInput(from item: AudioInputItem) -> QueueInput {
        QueueInput(
            urlPath: item.url.standardizedFileURL.path(percentEncoded: false),
            sourceRootPath: item.sourceRoot?.standardizedFileURL.path(percentEncoded: false),
            relativeDirectory: item.relativeDirectory
        )
    }

    private func applyQueueSettings(_ settings: QueueSettings) -> Bool {
        var requestedOutputMode = outputMode
        if let rawValue = settings.outputMode,
            let value = OutputMode(rawValue: rawValue)
        {
            requestedOutputMode = value
        }

        if let exportFolderPath = settings.exportFolderPath {
            exportFolder = directoryURLIfExists(atPath: exportFolderPath)
        } else {
            exportFolder = nil
        }

        if let rawValue = settings.encodingWorkflow,
            let value = EncodingWorkflow(rawValue: rawValue)
        {
            encodingWorkflow = value
        }

        if let selectedInputExtensions = settings.selectedInputExtensions {
            setSelectedInputExtensions(Set(selectedInputExtensions))
        }
        if let selectedVideoInputExtensions = settings.selectedVideoInputExtensions {
            setSelectedVideoInputExtensions(Set(selectedVideoInputExtensions))
        }

        if let value = settings.preserveSubfolders {
            preserveSubfolders = value
        }
        if let value = settings.overwriteExisting {
            overwriteExisting = value
        }
        if let rawValue = settings.outputFormat,
            let value = AudioOutputFormat(rawValue: rawValue)
        {
            outputFormat = value
        }
        if let rawValue = settings.videoOutputContainer,
            let value = VideoOutputContainer(rawValue: rawValue)
        {
            videoOutputContainer = value
        }
        if let rawValue = settings.hevcPreset,
            let value = HEVCVideoPreset(rawValue: rawValue)
        {
            hevcPreset = value
        }
        if let value = settings.customVideoBitrateKbps {
            customVideoBitrateKbps = max(500, min(value, 100_000))
        }
        if let rawValue = settings.videoScaleMode,
            let value = VideoScaleMode(rawValue: rawValue)
        {
            videoScaleMode = value
        }
        if let rawValue = settings.videoAudioMode,
            let value = VideoAudioMode(rawValue: rawValue)
        {
            videoAudioMode = value
        }
        if let rawValue = settings.videoHardwareDecodeMode,
            let value = VideoHardwareDecodeMode(rawValue: rawValue)
        {
            videoHardwareDecodeMode = value
        }
        if let rawValue = settings.mp3Mode,
            let value = MP3EncodingMode(rawValue: rawValue)
        {
            mp3Mode = value
        }
        if let value = settings.vbrQuality,
            MP3EncodingOptions.vbrQualities.contains(value)
        {
            vbrQuality = value
        }
        if let value = settings.cbrBitrateKbps,
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            cbrBitrateKbps = value
        }
        if let value = settings.abrBitrateKbps,
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            abrBitrateKbps = value
        }
        if let rawValue = settings.oggMode,
            let value = OggEncodingOptions.Mode(rawValue: rawValue)
        {
            oggMode = value
        }
        if let value = settings.oggQuality,
            OggEncodingOptions.qualities.contains(value)
        {
            oggQuality = value
        }
        if let value = settings.oggBitrateKbps,
            OggEncodingOptions.bitrateKbps.contains(value)
        {
            oggBitrateKbps = value
        }
        if let rawValue = settings.opusRateMode,
            let value = OpusEncodingOptions.RateMode(rawValue: rawValue)
        {
            opusRateMode = value
        }
        if let value = settings.opusBitrateKbps,
            OpusEncodingOptions.bitrateKbps.contains(value)
        {
            opusBitrateKbps = value
        }
        if let value = settings.flacCompressionLevel,
            FLACEncodingOptions.compressionLevels.contains(value)
        {
            flacCompressionLevel = value
        }
        if let value = settings.splitOversizedMultichannel {
            splitOversizedMultichannel = value
        }
        if let value = settings.parallelJobs {
            parallelJobs = max(1, min(value, processorLimit))
        }
        if let value = settings.ffmpegThreads {
            ffmpegThreads = max(0, min(value, processorLimit))
        }

        outputMode = requestedOutputMode
        if requestedOutputMode == .exportFolder, exportFolder == nil {
            outputMode = .sourceFolders
            return true
        }

        return false
    }

    private func loadInputs(from entries: [QueueInput]) -> QueueLoadResult {
        var items: [AudioInputItem] = []
        var seenPaths = Set<String>()
        var result = QueueLoadResult()

        for entry in entries {
            let url = URL(fileURLWithPath: entry.urlPath)
            let standardizedPath = url.standardizedFileURL.path

            guard regularFileExists(atPath: standardizedPath) else {
                result.missing += 1
                continue
            }

            guard isSupportedInput(url) else {
                result.unsupported += 1
                continue
            }

            guard !seenPaths.contains(standardizedPath) else {
                result.duplicates += 1
                continue
            }

            let sourceRoot = entry.sourceRootPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let size =
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let relativeDirectory =
                entry.relativeDirectory ?? relativeDirectory(for: url, sourceRoot: sourceRoot)

            items.append(
                AudioInputItem(
                    url: url,
                    sourceRoot: sourceRoot,
                    relativeDirectory: relativeDirectory,
                    fileSizeBytes: size
                )
            )
            seenPaths.insert(standardizedPath)
        }

        result.items = items
        return result
    }

    private func regularFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func directoryURLIfExists(atPath path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func loadPersistedSettings() {
        isLoadingPersistedSettings = true
        defer { isLoadingPersistedSettings = false }

        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: DefaultsKey.trashedSourceRecords),
            let records = try? JSONDecoder().decode([TrashedSourceRecord].self, from: data)
        {
            trashedSourceRecords = records
        }
        if let data = defaults.data(forKey: DefaultsKey.mediaRenameHistory),
            let document = try? JSONDecoder().decode(MediaRenameHistoryDocument.self, from: data),
            document.version == MediaRenameHistoryDocument.currentVersion
        {
            mediaRenameUndoStack = Array(document.undoStack.suffix(Self.mediaRenameHistoryLimit))
            mediaRenameRedoStack = Array(document.redoStack.suffix(Self.mediaRenameHistoryLimit))
        }
        loadMediaRenameSettings(from: defaults)
        loadEncodingPresets(from: defaults)
        loadPendingTrashSourceRecords()

        if let rawValue = defaults.string(forKey: DefaultsKey.ffmpegSourcePreference),
            let value = FFmpegSourcePreference(rawValue: rawValue),
            FFmpegSourcePreference.selectableCases.contains(value)
        {
            ffmpegSourcePreference = value
        } else if FFmpegLocator.bundledFFmpegURL() == nil,
            FFmpegLocator.systemFFmpegURL() != nil
        {
            ffmpegSourcePreference = .system
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.fileManagementMode),
            let value = FileManagementMode(rawValue: rawValue)
        {
            fileManagementMode = value
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.outputMode),
            let persistedOutputMode = OutputMode(rawValue: rawValue)
        {
            outputMode = persistedOutputMode
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.encodingWorkflow),
            let persistedWorkflow = EncodingWorkflow(rawValue: rawValue)
        {
            encodingWorkflow = persistedWorkflow
        }

        exportFolder = persistedDirectoryURL(forKey: DefaultsKey.exportFolderPath)
        if outputMode == .exportFolder, exportFolder == nil {
            outputMode = .sourceFolders
        }

        restoreDeletedFolder = persistedDirectoryURL(forKey: DefaultsKey.restoreDeletedFolderPath)
        restoreBackupRoot = persistedDirectoryURL(forKey: DefaultsKey.restoreBackupRootPath)
        restoreDestinationRoot = persistedDirectoryURL(
            forKey: DefaultsKey.restoreDestinationRootPath
        )
        if let paths = defaults.array(forKey: DefaultsKey.mediaCopySourceRootPaths) as? [String] {
            mediaCopySourceRoots = paths.compactMap { directoryURLIfExists(atPath: $0) }
        } else if let sourceRoot = persistedDirectoryURL(forKey: DefaultsKey.mediaCopySourceRootPath) {
            mediaCopySourceRoots = [sourceRoot]
        }
        mediaCopyDestinationRoot = persistedDirectoryURL(
            forKey: DefaultsKey.mediaCopyDestinationRootPath
        )
        if let rawValue = defaults.string(forKey: DefaultsKey.mediaCopyFilter),
            let value = MediaFileFilter(rawValue: rawValue)
        {
            mediaCopyFilter = value
        }
        mediaFileNameFilterQuery =
            defaults.string(forKey: DefaultsKey.mediaFileNameFilterQuery) ?? ""
        if let extensions = defaults.array(forKey: DefaultsKey.mediaCopyAudioExtensions) as? [String] {
            mediaCopyAudioExtensions = Set(extensions.map { $0.lowercased() })
                .intersection(MediaFileFilter.audio.fileExtensions)
        }
        if let extensions = defaults.array(forKey: DefaultsKey.mediaCopyVideoExtensions) as? [String] {
            mediaCopyVideoExtensions = Set(extensions.map { $0.lowercased() })
                .intersection(MediaFileFilter.video.fileExtensions)
        }

        if let selectedInputExtensions = defaults.array(forKey: DefaultsKey.selectedInputExtensions)
            as? [String]
        {
            setSelectedInputExtensions(Set(selectedInputExtensions))
        }
        if let selectedVideoInputExtensions = defaults.array(
            forKey: DefaultsKey.selectedVideoInputExtensions
        ) as? [String] {
            setSelectedVideoInputExtensions(Set(selectedVideoInputExtensions))
        }

        if let value = persistedBool(forKey: DefaultsKey.preserveSubfolders) {
            preserveSubfolders = value
        }

        if let value = persistedBool(forKey: DefaultsKey.overwriteExisting) {
            overwriteExisting = value
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.outputFormat),
            let persistedOutputFormat = AudioOutputFormat(rawValue: rawValue)
        {
            outputFormat = persistedOutputFormat
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.videoOutputContainer),
            let persistedVideoContainer = VideoOutputContainer(rawValue: rawValue)
        {
            videoOutputContainer = persistedVideoContainer
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.hevcPreset),
            let persistedHEVCPreset = HEVCVideoPreset(rawValue: rawValue)
        {
            hevcPreset = persistedHEVCPreset
        }

        if let value = persistedInt(forKey: DefaultsKey.customVideoBitrateKbps) {
            customVideoBitrateKbps = max(500, min(value, 100_000))
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.videoScaleMode),
            let persistedVideoScaleMode = VideoScaleMode(rawValue: rawValue)
        {
            videoScaleMode = persistedVideoScaleMode
        } else {
            videoScaleMode = hevcPreset.defaultScaleMode
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.videoAudioMode),
            let persistedVideoAudioMode = VideoAudioMode(rawValue: rawValue)
        {
            videoAudioMode = persistedVideoAudioMode
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.videoHardwareDecodeMode),
            let persistedVideoHardwareDecodeMode = VideoHardwareDecodeMode(rawValue: rawValue)
        {
            videoHardwareDecodeMode = persistedVideoHardwareDecodeMode
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.mp3Mode),
            let persistedMP3Mode = MP3EncodingMode(rawValue: rawValue)
        {
            mp3Mode = persistedMP3Mode
        }

        if let value = persistedInt(forKey: DefaultsKey.vbrQuality),
            MP3EncodingOptions.vbrQualities.contains(value)
        {
            vbrQuality = value
        }

        if let value = persistedInt(forKey: DefaultsKey.cbrBitrateKbps),
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            cbrBitrateKbps = value
        }

        if let value = persistedInt(forKey: DefaultsKey.abrBitrateKbps),
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            abrBitrateKbps = value
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.oggMode),
            let value = OggEncodingOptions.Mode(rawValue: rawValue)
        {
            oggMode = value
        }

        if let value = persistedInt(forKey: DefaultsKey.oggQuality),
            OggEncodingOptions.qualities.contains(value)
        {
            oggQuality = value
        }

        if let value = persistedInt(forKey: DefaultsKey.oggBitrateKbps),
            OggEncodingOptions.bitrateKbps.contains(value)
        {
            oggBitrateKbps = value
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.opusRateMode),
            let value = OpusEncodingOptions.RateMode(rawValue: rawValue)
        {
            opusRateMode = value
        }

        if let value = persistedInt(forKey: DefaultsKey.opusBitrateKbps),
            OpusEncodingOptions.bitrateKbps.contains(value)
        {
            opusBitrateKbps = value
        }

        if let value = persistedInt(forKey: DefaultsKey.flacCompressionLevel),
            FLACEncodingOptions.compressionLevels.contains(value)
        {
            flacCompressionLevel = value
        }

        if let value = persistedBool(forKey: DefaultsKey.splitOversizedMultichannel) {
            splitOversizedMultichannel = value
        }

        if let value = persistedInt(forKey: DefaultsKey.parallelJobs) {
            parallelJobs = max(1, min(value, processorLimit))
        }

        if let value = persistedInt(forKey: DefaultsKey.ffmpegThreads) {
            ffmpegThreads = max(0, min(value, processorLimit))
        }
    }

    private func persistedBool(forKey key: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func persistedInt(forKey key: String) -> Int? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    private func persistedDirectoryURL(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func lastInputDirectoryURL() -> URL? {
        persistedDirectoryURL(forKey: DefaultsKey.lastInputDirectoryPath)
    }

    private func rememberInputDirectory(fromFiles urls: [URL]) {
        guard let url = urls.first else { return }
        rememberInputDirectory(url.deletingLastPathComponent())
    }

    private func rememberInputDirectory(_ url: URL?) {
        guard let url else { return }
        UserDefaults.standard.set(
            url.standardizedFileURL.path(percentEncoded: false),
            forKey: DefaultsKey.lastInputDirectoryPath
        )
    }

    private func persistOptionalDirectory(_ url: URL?, forKey key: String) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(
            url.standardizedFileURL.path(percentEncoded: false),
            forKey: key
        )
    }

    private func persistedUUID(forKey key: String) -> UUID? {
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        return UUID(uuidString: value)
    }

    private func persistOptionalUUID(_ id: UUID?, forKey key: String) {
        guard !isLoadingPersistedSettings else { return }
        guard let id else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    private func persistMediaCopySourceRoots() {
        let paths = mediaCopySourceRoots.map {
            $0.standardizedFileURL.path(percentEncoded: false)
        }

        if paths.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.mediaCopySourceRootPaths)
            UserDefaults.standard.removeObject(forKey: DefaultsKey.mediaCopySourceRootPath)
        } else {
            UserDefaults.standard.set(paths, forKey: DefaultsKey.mediaCopySourceRootPaths)
            UserDefaults.standard.set(paths[0], forKey: DefaultsKey.mediaCopySourceRootPath)
        }
    }

    private func selectedExtensions(for filter: MediaFileFilter) -> Set<String>? {
        switch filter {
        case .all:
            nil
        case .audio:
            mediaCopyAudioExtensions
        case .video:
            mediaCopyVideoExtensions
        }
    }

    private var currentSupportedInputExtensions: Set<String> {
        switch encodingWorkflow {
        case .audio:
            AudioFormat.inputExtensions
        case .video:
            VideoFormat.inputExtensions
        }
    }

    private var currentSelectedInputExtensions: Set<String> {
        switch encodingWorkflow {
        case .audio:
            selectedInputExtensions
        case .video:
            selectedVideoInputExtensions
        }
    }

    private func persistMediaCopyExtensions(_ extensions: Set<String>, forKey key: String) {
        UserDefaults.standard.set(extensions.sorted(), forKey: key)
    }

    private func chooseDirectory(title: String, prompt: String, initialURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseDirectories(title: String, prompt: String, initialURL: URL?) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func validateMediaCopyFolders(sourceRoot: URL, destinationRoot: URL) -> Bool {
        let sourceComponents = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let destinationComponents =
            destinationRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        if sourceComponents == destinationComponents {
            showMediaCopyFolderAlert(
                message: "Choose different folders",
                detail:
                    "The source and destination folders are the same. Choose a destination folder on the target volume."
            )
            return false
        }

        if destinationComponents.count > sourceComponents.count
            && Array(destinationComponents.prefix(sourceComponents.count)) == sourceComponents
        {
            showMediaCopyFolderAlert(
                message: "Destination is inside the source",
                detail:
                    "Choose a destination outside the source tree so copied files are not scanned again while the operation is running."
            )
            return false
        }

        return true
    }

    private func showMediaCopyFolderAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        statusMessage = detail
    }

    private func invalidateBackupRestorePlanIfChanged<T: Equatable>(from oldValue: T, to newValue: T) {
        guard oldValue != newValue else { return }
        restorePlanRecords.removeAll()
        restorePlanLiveCounts = nil
        restorePlanLiveUnresolvedItems.removeAll()
        restorePlanStoppedWithPartialResults = false
        restorePlanScanSummary = nil
        restorePlanProgress = nil
    }

    private func invalidateMediaCopyPlanIfChanged<T: Equatable>(from oldValue: T, to newValue: T) {
        guard oldValue != newValue, !isMediaCopyBusy else { return }
        mediaFileNameFilterRefreshTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        guard !isLoadingPersistedSettings else { return }

        if mediaCopySourceRoots.isEmpty {
            mediaFileInventory = []
            mediaFileInventorySourceRootPaths = []
            mediaDeletePlan = nil
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            return
        }

        switch fileManagementMode {
        case .copy:
            mediaDeletePlan = nil
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
        case .delete:
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            refreshMediaDeletePreviewIfNeeded()
        case .rename:
            mediaDeletePlan = nil
            refreshMediaRenamePreviewIfNeeded()
        }
    }

    private func handleMediaFileNameFilterChanged(from oldValue: String, to newValue: String) {
        guard oldValue != newValue, !isMediaCopyBusy else { return }
        mediaFileNameFilterRefreshTask?.cancel()
        mediaCopyPlan = nil
        mediaCopyProgress = nil

        guard !isLoadingPersistedSettings else { return }

        switch fileManagementMode {
        case .copy:
            mediaDeletePlan = nil
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
        case .delete:
            mediaDeletePlan = nil
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            scheduleFileNameFilterPreviewRefresh()
        case .rename:
            mediaDeletePlan = nil
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            scheduleFileNameFilterPreviewRefresh()
        }
    }

    private func scheduleFileNameFilterPreviewRefresh() {
        mediaFileNameFilterRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.mediaFileNameFilterDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isMediaCopyBusy else { return }
                self.refreshActiveFileManagementPreviewIfNeeded()
            }
        }
    }

    private func handleMediaRenameSettingChanged<T: Equatable>(from oldValue: T, to newValue: T) {
        guard oldValue != newValue else { return }
        if !isLoadingPersistedSettings {
            persistMediaRenameSettings()
        }
        invalidateMediaRenamePlanIfChanged(from: oldValue, to: newValue)
    }

    private func invalidateMediaRenamePlanIfChanged<T: Equatable>(from oldValue: T, to newValue: T) {
        guard oldValue != newValue, !isMediaCopyBusy, !isLoadingPersistedSettings else { return }
        mediaCopyProgress = nil
        guard fileManagementMode == .rename else { return }

        if mediaFileInventoryMatchesCurrentSources {
            rebuildMediaRenamePreviewFromInventory()
        } else if mediaRenamePlan != nil {
            isMediaRenamePreviewStale = true
            statusMessage = "Rename settings changed. Refresh the preview when ready."
        } else {
            refreshMediaRenamePreviewIfNeeded()
        }
    }

    private func persistTrashedSourceRecords() {
        if trashedSourceRecords.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.trashedSourceRecords)
            return
        }

        if let data = try? JSONEncoder().encode(trashedSourceRecords) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.trashedSourceRecords)
        }
    }

    private func persistMediaRenameHistory() {
        if mediaRenameUndoStack.isEmpty && mediaRenameRedoStack.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.mediaRenameHistory)
            return
        }

        let document = MediaRenameHistoryDocument(
            undoStack: mediaRenameUndoStack,
            redoStack: mediaRenameRedoStack
        )
        if let data = try? JSONEncoder().encode(document) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.mediaRenameHistory)
        }
    }

    private func persistMediaRenameSettings() {
        let settings = currentMediaRenameSettings()
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.mediaRenameSettings)
        }
    }

    private func persistEncodingPresets() {
        let document = EncodingPresetDocument(presets: encodingPresets)
        if let data = try? JSONEncoder().encode(document) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.encodingPresets)
        }
    }

    private func loadEncodingPresets(from defaults: UserDefaults) {
        if let data = defaults.data(forKey: DefaultsKey.encodingPresets) {
            switch EncodingPresetDocument.decode(from: data) {
            case .success(let presets):
                encodingPresets = presets
            case .failure(.versionMismatch):
                // Non-destructive: leave the blob on disk so a newer build can
                // still read it. Surface the problem instead of silently emptying.
                encodingPresets = []
                statusMessage = "Could not read saved presets — they were saved by a newer version and were kept on disk."
            case .failure(.corrupt):
                encodingPresets = []
                statusMessage = "Could not read saved presets — the saved data appears damaged and was kept on disk."
            }
        }

        selectedAudioEncodingPresetID = persistedUUID(forKey: DefaultsKey.selectedAudioEncodingPresetID)
        selectedVideoEncodingPresetID = persistedUUID(forKey: DefaultsKey.selectedVideoEncodingPresetID)
        normalizeSelectedEncodingPresetIDs()
    }

    private func normalizeSelectedEncodingPresetIDs() {
        let normalized = EncodingPreset.normalize(
            selectedAudioID: selectedAudioEncodingPresetID,
            selectedVideoID: selectedVideoEncodingPresetID,
            in: encodingPresets
        )
        selectedAudioEncodingPresetID = normalized.audioID
        selectedVideoEncodingPresetID = normalized.videoID
        // Persist even during the loading window so stale IDs don't linger in
        // the plist and get re-cleared on every launch.
        forcePersistOptionalUUID(normalized.audioID, forKey: DefaultsKey.selectedAudioEncodingPresetID)
        forcePersistOptionalUUID(normalized.videoID, forKey: DefaultsKey.selectedVideoEncodingPresetID)
    }

    private func forcePersistOptionalUUID(_ id: UUID?, forKey key: String) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func loadMediaRenameSettings(from defaults: UserDefaults) {
        guard let data = defaults.data(forKey: DefaultsKey.mediaRenameSettings),
            let settings = try? JSONDecoder().decode(MediaRenameSettings.self, from: data)
        else {
            return
        }

        mediaRenameOperation = settings.operation
        mediaRenamePattern = settings.pattern
        mediaRenameFindText = settings.findText
        mediaRenameReplacementText = settings.replacementText
        mediaRenameIsCaseSensitive = settings.isCaseSensitive
        mediaRenameAddedText = settings.addedText
        mediaRenameTextPlacement = settings.textPlacement
        mediaRenameCaseStyle = settings.caseStyle
        mediaRenameSort = settings.sort
        mediaRenameStartIndex = max(0, min(settings.startIndex, 999_999))
        mediaRenameIndexStep = max(1, min(settings.indexStep, 999))
        mediaRenameIndexPadding = max(1, min(settings.indexPadding, 8))
    }

    private func loadPendingTrashSourceRecords() {
        guard let url = try? trashEmergencyJournalURL() else { return }
        guard let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode([PendingTrashSourceRecord].self, from: data)
        else {
            return
        }

        pendingTrashSourceRecords = records
    }

    private func recordPendingTrashIntent(
        for item: AudioInputItem
    ) throws -> PendingTrashSourceRecord {
        let recordsByID = try recordPendingTrashIntents(for: [TrashableFileItem(audioInput: item)])
        guard let record = recordsByID[item.id] else {
            throw CocoaError(.fileWriteUnknown)
        }
        return record
    }

    private func recordPendingTrashIntents(
        for items: [AudioInputItem]
    ) throws -> [UUID: PendingTrashSourceRecord] {
        try recordPendingTrashIntents(for: items.map { TrashableFileItem(audioInput: $0) })
    }

    private func recordPendingTrashIntents(
        for items: [TrashableFileItem]
    ) throws -> [UUID: PendingTrashSourceRecord] {
        var nextRecords = pendingTrashSourceRecords
        var recordsByItemID: [UUID: PendingTrashSourceRecord] = [:]

        for item in items {
            let record = PendingTrashSourceRecord(
                id: item.id,
                name: item.name,
                originalPath: item.url.standardizedFileURL.path(percentEncoded: false),
                sourceRootPath: item.sourceRoot?.standardizedFileURL.path(percentEncoded: false),
                relativeDirectory: item.relativeDirectory,
                fileSizeBytes: item.fileSizeBytes
            )

            if let index = nextRecords.firstIndex(where: { $0.id == record.id }) {
                nextRecords[index] = record
            } else {
                nextRecords.insert(record, at: 0)
            }
            recordsByItemID[item.id] = record
        }

        try replacePendingTrashSourceRecords(nextRecords)
        return recordsByItemID
    }

    private func removePendingTrashRecords(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        var nextRecords = pendingTrashSourceRecords
        nextRecords.removeAll { ids.contains($0.id) }
        try replacePendingTrashSourceRecords(nextRecords)
    }

    private func removePendingTrashRecordIfOriginalStillExists(_ record: PendingTrashSourceRecord) {
        guard regularFileExists(atPath: record.originalPath) else { return }
        try? removePendingTrashRecords(ids: [record.id])
    }

    private func replacePendingTrashSourceRecords(
        _ records: [PendingTrashSourceRecord]
    ) throws {
        try persistPendingTrashSourceRecords(records)
        pendingTrashSourceRecords = records
    }

    private func persistPendingTrashSourceRecords(
        _ records: [PendingTrashSourceRecord]
    ) throws {
        let url = try trashEmergencyJournalURL()
        guard !records.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: [.atomic])
    }

    private func trashEmergencyJournalURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent(
            TrashEmergencyJournal.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL.appendingPathComponent(TrashEmergencyJournal.fileName)
    }

    private func setSelectedInputExtensions(_ extensions: Set<String>) {
        let supported = extensions.intersection(AudioFormat.inputExtensions)
        selectedInputExtensions = supported
        jobs.removeAll()
        jobStateFilter = nil
    }

    private func setSelectedVideoInputExtensions(_ extensions: Set<String>) {
        let supported = extensions.intersection(VideoFormat.inputExtensions)
        selectedVideoInputExtensions = supported
        jobs.removeAll()
        jobStateFilter = nil
    }

    private func moveItemToTrashAndRecord(
        _ item: TrashableFileItem,
        pendingRecord: PendingTrashSourceRecord
    ) throws -> TrashMoveRecordResult {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingItemURL)

        guard let trashURL = resultingItemURL as URL? else {
            return .emergencyJournalOnly
        }

        let record = TrashedSourceRecord(
            id: pendingRecord.id,
            name: item.name,
            originalPath: pendingRecord.originalPath,
            trashPath: trashURL.standardizedFileURL.path(percentEncoded: false),
            sourceRootPath: pendingRecord.sourceRootPath,
            relativeDirectory: pendingRecord.relativeDirectory,
            fileSizeBytes: pendingRecord.fileSizeBytes,
            trashedAt: pendingRecord.requestedAt
        )
        trashedSourceRecords.insert(record, at: 0)
        return .restoreLedgerRecorded
    }

    private func appendRestoredInput(from record: TrashedSourceRecord, restoredURL: URL) {
        guard isAnySupportedInput(restoredURL) else { return }

        let key = restoredURL.standardizedFileURL.path
        guard !inputs.contains(where: { $0.url.standardizedFileURL.path == key }) else { return }

        let sourceRoot = record.sourceRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let size =
            (try? restoredURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? record.fileSizeBytes
        let relativeDirectory =
            record.relativeDirectory ?? relativeDirectory(for: restoredURL, sourceRoot: sourceRoot)

        inputs.append(
            AudioInputItem(
                url: restoredURL,
                sourceRoot: sourceRoot,
                relativeDirectory: relativeDirectory,
                fileSizeBytes: size
            )
        )
        inputs.sort {
            $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
        }
    }

    private func appendRestoredFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var existing = Set(inputs.map { $0.url.standardizedFileURL.path })
        let sourceRoot = restoreDestinationRoot
        var additions: [AudioInputItem] = []

        for url in urls where isAnySupportedInput(url) {
            let key = url.standardizedFileURL.path
            guard !existing.contains(key) else { continue }
            additions.append(inputItem(for: url, sourceRoot: sourceRoot))
            existing.insert(key)
        }

        inputs.append(contentsOf: additions)
        inputs.sort {
            $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
        }
        jobs.removeAll()
        jobStateFilter = nil
        rememberInputDirectory(fromFiles: urls)
    }

    private func queueAddStatusMessage(for summary: AddSummary) -> String {
        guard summary.added > 0, !inputs.isEmpty else {
            return summary.message
        }

        return "\(summary.message) \(activeInputs.count) of \(inputs.count) queued file\(inputs.count == 1 ? "" : "s") active."
    }

    private func addFileURLs(_ urls: [URL]) -> AddSummary {
        var summary = AddSummary()
        var existing = Set(inputs.map { $0.url.standardizedFileURL.path })
        var additions: [AudioInputItem] = []

        for url in urls {
            guard isSupportedInput(url) else {
                summary.unsupported += 1
                continue
            }

            let key = url.standardizedFileURL.path
            guard !existing.contains(key) else {
                summary.duplicates += 1
                continue
            }

            additions.append(inputItem(for: url, sourceRoot: nil))
            existing.insert(key)
            summary.added += 1
        }

        inputs.append(
            contentsOf: additions.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        jobs.removeAll()
        jobStateFilter = nil
        return summary
    }

    private func addFolderURL(_ folder: URL) -> AddSummary {
        var summary = AddSummary()
        var existing = Set(inputs.map { $0.url.standardizedFileURL.path })
        var additions: [AudioInputItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        guard
            let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return summary
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            guard isSupportedInput(url) else {
                summary.unsupported += 1
                continue
            }

            let key = url.standardizedFileURL.path
            guard !existing.contains(key) else {
                summary.duplicates += 1
                continue
            }

            additions.append(inputItem(for: url, sourceRoot: folder))
            existing.insert(key)
            summary.added += 1
        }

        inputs.append(
            contentsOf: additions.sorted {
                $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
            })
        jobs.removeAll()
        jobStateFilter = nil
        return summary
    }

    private func inputItem(for url: URL, sourceRoot: URL?) -> AudioInputItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let relativeDirectory = relativeDirectory(for: url, sourceRoot: sourceRoot)

        return AudioInputItem(
            url: url,
            sourceRoot: sourceRoot,
            relativeDirectory: relativeDirectory,
            fileSizeBytes: size
        )
    }

    private func relativeDirectory(for url: URL, sourceRoot: URL?) -> String? {
        guard let sourceRoot else { return nil }
        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        let parentComponents = url.deletingLastPathComponent().standardizedFileURL.pathComponents

        guard parentComponents.count >= rootComponents.count,
            Array(parentComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        let relativeComponents = parentComponents.dropFirst(rootComponents.count)
        return relativeComponents.isEmpty ? nil : relativeComponents.joined(separator: "/")
    }

    private func isSupportedAudio(_ url: URL) -> Bool {
        AudioFormat.inputExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        VideoFormat.inputExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSupportedInput(_ url: URL) -> Bool {
        switch encodingWorkflow {
        case .audio:
            isSupportedAudio(url)
        case .video:
            isSupportedVideo(url)
        }
    }

    private func isAnySupportedInput(_ url: URL) -> Bool {
        isSupportedAudio(url) || isSupportedVideo(url)
    }

    private func isSelectedInput(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return currentSupportedInputExtensions.contains(fileExtension)
            && currentSelectedInputExtensions.contains(fileExtension)
    }

    nonisolated private static func mediaCopyScanStatusMessage(for plan: MediaCopyPlan) -> String {
        guard plan.hasCopyableContent else {
            return "No \(plan.filter.fileTypeName) files found in \(plan.sourceRoot.lastPathComponent)."
        }

        var details = [
            "Found \(plan.candidateCount) \(plan.filter.fileTypeName) file\(plan.candidateCount == 1 ? "" : "s")",
            "totaling \(plan.totalSizeBytes.formattedFileSize)"
        ]
        if plan.directoryCount > 0 {
            details.append(
                "\(plan.directoryCount) folder\(plan.directoryCount == 1 ? "" : "s")"
            )
        }
        if plan.conflictCount > 0 {
            details.append(
                "\(plan.conflictCount) existing destination file\(plan.conflictCount == 1 ? "" : "s")"
            )
        }
        return details.joined(separator: ", ") + "."
    }

    nonisolated private static func mediaDeleteScanStatusMessage(for plan: MediaDeletePlan) -> String {
        let scopeDescription = mediaDeleteScopeDescription(
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter
        )
        guard plan.hasDeletableContent else {
            return "No files matching \(scopeDescription) were found in the selected source folders."
        }

        return
            "Found \(plan.candidateCount) file\(plan.candidateCount == 1 ? "" : "s") matching \(scopeDescription), totaling \(plan.totalSizeBytes.formattedFileSize)."
    }

    nonisolated private static func mediaDeleteScopeDescription(
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter
    ) -> String {
        let typeDescription =
            filter.supportsExtensionSelection
            ? filter.readableExtensionList(selectedExtensions: selectedExtensions)
            : "all files"
        let nameQuery = fileNameFilter.trimmedQuery
        guard !nameQuery.isEmpty else { return typeDescription }
        return "\(typeDescription) with names containing \"\(nameQuery)\""
    }

    nonisolated private static func mediaRenameScanStatusMessage(for plan: MediaRenamePlan) -> String {
        guard plan.hasRenameContent else {
            if let selectedExtensions = plan.selectedExtensions {
                return "No \(plan.filter.fileTypeName) files matching \(plan.filter.readableExtensionList(selectedExtensions: selectedExtensions)) were found in the selected source folders."
            }
            return "No matching files were found in the selected source folders."
        }

        var details = [
            "Found \(plan.itemCount) file\(plan.itemCount == 1 ? "" : "s") for rename preview",
            "\(plan.readyCount) ready"
        ]
        if plan.unchangedCount > 0 {
            details.append("\(plan.unchangedCount) unchanged")
        }
        if plan.blockedCount > 0 {
            details.append("\(plan.blockedCount) blocked")
        }
        details.append("totaling \(plan.totalSizeBytes.formattedFileSize)")
        return details.joined(separator: ", ") + "."
    }

    nonisolated private static func mediaCopyResultStatusMessage(
        _ result: MediaCopyResult,
        filter: MediaFileFilter,
        destinationRoot: URL
    ) -> String {
        if result.cancelled {
            return "Media copy cancelled after \(result.copied) copied file\(result.copied == 1 ? "" : "s")."
        }

        var details = [
            "Copied \(result.copied) \(filter.fileTypeName) file\(result.copied == 1 ? "" : "s") to \(destinationRoot.lastPathComponent)."
        ]
        if result.createdDirectories > 0 {
            details.append(
                "Created \(result.createdDirectories) folder\(result.createdDirectories == 1 ? "" : "s")."
            )
        }
        if result.skippedExisting > 0 {
            details.append("Skipped \(result.skippedExisting) existing file\(result.skippedExisting == 1 ? "" : "s").")
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        if result.failedDirectories > 0 {
            details.append(
                "Failed \(result.failedDirectories) folder\(result.failedDirectories == 1 ? "" : "s"): \(result.failedDirectoryNames.prefix(3).joined(separator: ", "))\(result.failedDirectoryNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    nonisolated private static func mediaRenameResultStatusMessage(
        _ result: MediaRenameResult
    ) -> String {
        if result.cancelled {
            return "Rename cancelled after \(result.renamed) renamed file\(result.renamed == 1 ? "" : "s")."
        }

        var details = [
            "Renamed \(result.renamed) file\(result.renamed == 1 ? "" : "s")."
        ]
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    nonisolated private static func mediaRenameHistoryResultStatusMessage(
        _ result: MediaRenameHistoryResult,
        direction: MediaRenameHistoryDirection
    ) -> String {
        if result.cancelled {
            return "\(direction.title) cancelled after \(result.moved) file\(result.moved == 1 ? "" : "s") \(direction.progressVerb)."
        }

        var details = [
            "\(direction.title) complete: \(result.moved) file\(result.moved == 1 ? "" : "s") \(direction.progressVerb)."
        ]
        if result.failed > 0 {
            details.append(
                "Skipped \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    nonisolated private static func mediaCopyQueueResultStatusMessage(
        _ result: MediaCopyResult,
        workflowCount: Int
    ) -> String {
        if result.cancelled {
            return "File copy queue cancelled after \(result.copied) copied file\(result.copied == 1 ? "" : "s")."
        }

        var details = [
            "Finished \(workflowCount) file copy workflow\(workflowCount == 1 ? "" : "s"): \(result.copied) copied."
        ]
        if result.createdDirectories > 0 {
            details.append(
                "\(result.createdDirectories) folder\(result.createdDirectories == 1 ? "" : "s") created."
            )
        }
        if result.skippedExisting > 0 {
            details.append("\(result.skippedExisting) existing file\(result.skippedExisting == 1 ? "" : "s") skipped.")
        }
        if result.failed > 0 {
            details.append(
                "\(result.failed) failed: \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        if result.failedDirectories > 0 {
            details.append(
                "\(result.failedDirectories) folder failure\(result.failedDirectories == 1 ? "" : "s")."
            )
        }
        return details.joined(separator: " ")
    }

    private func outputURL(for item: AudioInputItem) -> URL {
        let outputDirectory: URL

        switch outputMode {
        case .sourceFolders:
            outputDirectory = item.url.deletingLastPathComponent()
        case .exportFolder:
            let base = exportFolder ?? item.url.deletingLastPathComponent()
            if preserveSubfolders, let relativeDirectory = item.relativeDirectory {
                outputDirectory = base.appendingPathComponent(relativeDirectory, isDirectory: true)
            } else {
                outputDirectory = base
            }
        }

        switch encodingWorkflow {
        case .audio:
            return outputDirectory.appendingPathComponent(item.outputFileName(for: outputFormat))
        case .video:
            return outputDirectory.appendingPathComponent(
                item.outputFileName(for: videoOutputContainer)
            )
        }
    }

    private func runJobs(settings: EncodingSettingsSnapshot) async {
        await withTaskGroup(of: JobResult.self) { group in
            var nextIndex = 0
            let initialCount = min(settings.parallelJobs, jobs.count)

            while nextIndex < initialCount {
                let job = markJobRunning(at: nextIndex)
                let reporter = EncodingProgressReporter(model: self, jobID: job.id)
                group.addTask {
                    await Self.encode(job: job, settings: settings, progressReporter: reporter)
                }
                nextIndex += 1
            }

            while let result = await group.next() {
                apply(result)

                if Task.isCancelled {
                    continue
                }

                if nextIndex < jobs.count {
                    let job = markJobRunning(at: nextIndex)
                    let reporter = EncodingProgressReporter(model: self, jobID: job.id)
                    group.addTask {
                        await Self.encode(job: job, settings: settings, progressReporter: reporter)
                    }
                    nextIndex += 1
                }
            }
        }

        if Task.isCancelled {
            for index in jobs.indices
            where jobs[index].state == .queued || jobs[index].state == .running {
                jobs[index].state = .cancelled
                jobs[index].message = "Cancelled."
                jobs[index].finishedAt = Date()
            }
        }

        isEncoding = false
        encodeTask = nil

        let completionTitle: String
        let completionMessage: String
        if Task.isCancelled {
            completionTitle = "Encoding stopped"
            completionMessage =
                "Encoding cancelled. \(completedCount) completed, \(failedCount) failed, \(skippedCount) skipped."
        } else if failedCount > 0 {
            completionTitle = "Encoding finished with failures"
            completionMessage =
                "Finished with \(failedCount) failure\(failedCount == 1 ? "" : "s")."
        } else if skippedCount > 0 {
            completionTitle = "Encoding finished"
            completionMessage =
                "Finished. \(skippedCount) file\(skippedCount == 1 ? "" : "s") skipped."
        } else if completedCount > 0 {
            completionTitle = "Encoding finished"
            completionMessage =
                "Finished \(completedCount) \(settings.encodingWorkflow.title.lowercased()) export\(completedCount == 1 ? "" : "s")."
        } else {
            completionTitle = "Encoding finished"
            completionMessage = "No files were encoded."
        }

        statusMessage = completionMessage
        AppNotifier.notifyIfAppInactive(title: completionTitle, body: completionMessage)
    }

    private func markJobRunning(at index: Int) -> EncodeJob {
        jobs[index].state = .running
        jobs[index].message = "Encoding..."
        jobs[index].diagnosticMessage = ""
        jobs[index].startedAt = Date()
        return jobs[index]
    }

    private static func encode(job: EncodeJob, settings: EncodingSettingsSnapshot) async
        -> JobResult
    {
        await encode(job: job, settings: settings, progressReporter: nil)
    }

    private static func encode(
        job: EncodeJob,
        settings: EncodingSettingsSnapshot,
        progressReporter: EncodingProgressReporter?
    ) async
        -> JobResult
    {
        let encoder = FFmpegEncoder(ffmpegURL: settings.ffmpegURL)

        do {
            let output = try await encoder.encode(
                input: job.item.url,
                output: job.outputURL,
                settings: settings
            ) { progress in
                progressReporter?.report(progress)
            }
            return .success(job.id, output)
        } catch EncodeSkipError.outputExists {
            return .skipped(job.id, "Output already exists.")
        } catch is CancellationError {
            return .cancelled(job.id)
        } catch {
            return .failure(
                job.id,
                error.localizedDescription,
                failureDiagnosticMessage(for: job, settings: settings, error: error)
            )
        }
    }

    private static func failureDiagnosticMessage(
        for job: EncodeJob,
        settings: EncodingSettingsSnapshot,
        error: Error
    ) -> String {
        [
            "GPhilCoder encoding failed",
            "Input: \(job.item.url.path(percentEncoded: false))",
            "Output: \(job.outputURL.path(percentEncoded: false))",
            "FFmpeg: \(settings.ffmpegURL.path(percentEncoded: false))",
            "Settings: \(settings.summary)",
            "FFmpeg threads: \(settings.ffmpegThreads == 0 ? "Auto" : "\(settings.ffmpegThreads)")",
            "",
            "Error:",
            error.localizedDescription
        ].joined(separator: "\n")
    }

    private func apply(_ result: JobResult) {
        guard let index = jobs.firstIndex(where: { $0.id == result.jobID }) else { return }
        jobs[index].finishedAt = Date()

        switch result {
        case .success(_, let output):
            jobs[index].state = .succeeded
            jobs[index].message = summarizeFFmpegOutput(output)
            jobs[index].diagnosticMessage = ""
        case .skipped(_, let message):
            jobs[index].state = .skipped
            jobs[index].message = message
            jobs[index].diagnosticMessage = ""
        case .failure(_, let message, let diagnosticMessage):
            jobs[index].state = .failed
            jobs[index].message = message
            jobs[index].diagnosticMessage = diagnosticMessage
        case .cancelled:
            jobs[index].state = .cancelled
            jobs[index].message = "Cancelled."
            jobs[index].diagnosticMessage = ""
        }
    }

    func updateJobProgress(jobID: UUID, progress: FFmpegProgressSnapshot) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
            jobs[index].state == .running
        else {
            return
        }
        jobs[index].message = progress.message
    }

    private func summarizeFFmpegOutput(_ output: String) -> String {
        let lines =
            output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return lines.last(where: { $0.contains("audio:") || $0.contains("video:") })
            ?? "Output written."
    }
}

private final class EncodingProgressReporter: @unchecked Sendable {
    weak var model: EncoderViewModel?
    let jobID: UUID

    init(model: EncoderViewModel, jobID: UUID) {
        self.model = model
        self.jobID = jobID
    }

    func report(_ progress: FFmpegProgressSnapshot) {
        Task { @MainActor [weak model] in
            model?.updateJobProgress(jobID: jobID, progress: progress)
        }
    }
}

private enum JobResult {
    case success(UUID, String)
    case skipped(UUID, String)
    case failure(UUID, String, String)
    case cancelled(UUID)

    var jobID: UUID {
        switch self {
        case .success(let id, _),
            .skipped(let id, _),
            .failure(let id, _, _),
            .cancelled(let id):
            id
        }
    }
}

private struct QueueLoadResult {
    var items: [AudioInputItem] = []
    var missing = 0
    var unsupported = 0
    var duplicates = 0
}
