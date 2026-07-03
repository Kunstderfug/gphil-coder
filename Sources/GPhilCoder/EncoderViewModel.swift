import AppKit
import Combine
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
        static let confirmBeforeEncoding = "confirmBeforeEncoding"
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
        static let syncFolderPairs = "syncFolderPairs"
        static let syncOverwriteExisting = "syncOverwriteExisting"
        static let syncDeleteDestinationItems = "syncDeleteDestinationItems"
        static let syncAutoSyncEnabled = "syncAutoSyncEnabled"
        static let syncDestinationLayout = "syncDestinationLayout"
        static let syncFileFilter = "syncFileFilter"
        static let syncCustomFileExtensions = "syncCustomFileExtensions"
        static let completionNotificationsEnabled = "completionNotificationsEnabled"
    }

    private static let mediaRenameHistoryLimit = 20
    private static let mediaPreviewLimit = 300
    private static let mediaFileNameFilterDebounceNanoseconds: UInt64 = 400_000_000
    private static let syncPreviewLimit = 300

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

    private enum SyncFolderPairListFile {
        static let fileExtension = "gphilcodersync"

        static var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .json
        }
    }

    private enum TrashEmergencyJournal {
        static let directoryName = "GPhilCoder"
        static let fileName = "trash-emergency-journal.json"
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

    private struct MediaRenameHistoryDocument: Codable, Sendable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var undoStack: [MediaRenameHistoryTransaction]
        var redoStack: [MediaRenameHistoryTransaction]
    }

    /// Versioned wrapper around `MediaRenameSettings`, mirroring the
    /// `VersionedBlob` envelope shape so a corrupt blob can be distinguished
    /// from a missing one.
    private struct MediaRenameSettingsDocument: Codable, Sendable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var settings: MediaRenameSettings
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
    var fileManagementMode: FileManagementMode {
        get { mediaFileCoordinator.fileManagementMode }
        set {
            let oldValue = mediaFileCoordinator.fileManagementMode
            guard oldValue != newValue else { return }
            mediaFileCoordinator.fileManagementMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.fileManagementMode)
            guard !isLoadingPersistedSettings else { return }
            refreshActiveFileManagementPreviewIfNeeded()
        }
    }
    var mediaCopySourceRoots: [URL] {
        get { mediaFileCoordinator.mediaCopySourceRoots }
        set {
            let oldValue = mediaFileCoordinator.mediaCopySourceRoots
            mediaFileCoordinator.mediaCopySourceRoots = newValue
            persistMediaCopySourceRoots()
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
        }
    }
    var mediaCopyDestinationRoot: URL? {
        get { mediaFileCoordinator.mediaCopyDestinationRoot }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyDestinationRoot
            mediaFileCoordinator.mediaCopyDestinationRoot = newValue
            persistOptionalDirectory(newValue, forKey: DefaultsKey.mediaCopyDestinationRootPath)
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
        }
    }
    var mediaCopyFilter: MediaFileFilter {
        get { mediaFileCoordinator.mediaCopyFilter }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyFilter
            mediaFileCoordinator.mediaCopyFilter = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.mediaCopyFilter)
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
        }
    }
    private(set) var mediaCopyAudioExtensions: Set<String> {
        get { mediaFileCoordinator.mediaCopyAudioExtensions }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyAudioExtensions
            mediaFileCoordinator.mediaCopyAudioExtensions = newValue
            persistMediaCopyExtensions(newValue, forKey: DefaultsKey.mediaCopyAudioExtensions)
            if mediaCopyFilter == .audio {
                invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
            }
        }
    }
    private(set) var mediaCopyVideoExtensions: Set<String> {
        get { mediaFileCoordinator.mediaCopyVideoExtensions }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyVideoExtensions
            mediaFileCoordinator.mediaCopyVideoExtensions = newValue
            persistMediaCopyExtensions(newValue, forKey: DefaultsKey.mediaCopyVideoExtensions)
            if mediaCopyFilter == .video {
                invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
            }
        }
    }
    var mediaFileNameFilterQuery: String {
        get { mediaFileCoordinator.mediaFileNameFilterQuery }
        set {
            let oldValue = mediaFileCoordinator.mediaFileNameFilterQuery
            mediaFileCoordinator.mediaFileNameFilterQuery = newValue
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.mediaFileNameFilterQuery)
            handleMediaFileNameFilterChanged(
                from: oldValue.trimmingCharacters(in: .whitespacesAndNewlines),
                to: newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
    var mediaCopyPlan: MediaCopyPlan? {
        get { mediaFileCoordinator.mediaCopyPlan }
        set { mediaFileCoordinator.mediaCopyPlan = newValue }
    }
    var mediaDeletePlan: MediaDeletePlan? {
        get { mediaFileCoordinator.mediaDeletePlan }
        set { mediaFileCoordinator.mediaDeletePlan = newValue }
    }
    var mediaRenamePlan: MediaRenamePlan? {
        get { mediaFileCoordinator.mediaRenamePlan }
        set { mediaFileCoordinator.mediaRenamePlan = newValue }
    }
    var isMediaRenamePreviewStale: Bool {
        get { mediaFileCoordinator.isMediaRenamePreviewStale }
        set { mediaFileCoordinator.isMediaRenamePreviewStale = newValue }
    }
    var mediaCopyProgress: MediaCopyProgress? {
        get { mediaFileCoordinator.mediaCopyProgress }
        set { mediaFileCoordinator.mediaCopyProgress = newValue }
    }
    var isMediaCopyScanning: Bool {
        get { mediaFileCoordinator.isMediaCopyScanning }
        set { mediaFileCoordinator.isMediaCopyScanning = newValue }
    }
    var isMediaCopying: Bool {
        get { mediaFileCoordinator.isMediaCopying }
        set { mediaFileCoordinator.isMediaCopying = newValue }
    }
    var isMediaDeleting: Bool {
        get { mediaFileCoordinator.isMediaDeleting }
        set { mediaFileCoordinator.isMediaDeleting = newValue }
    }
    var isMediaRenaming: Bool {
        get { mediaFileCoordinator.isMediaRenaming }
        set { mediaFileCoordinator.isMediaRenaming = newValue }
    }
    var mediaRenameProgressVerb: String {
        get { mediaFileCoordinator.mediaRenameProgressVerb }
        set { mediaFileCoordinator.mediaRenameProgressVerb = newValue }
    }
    var mediaCopyQueue: [MediaCopyWorkflow] {
        get { mediaFileCoordinator.mediaCopyQueue }
        set { mediaFileCoordinator.mediaCopyQueue = newValue }
    }
    var currentMediaCopyWorkflowID: UUID? {
        get { mediaFileCoordinator.currentMediaCopyWorkflowID }
        set { mediaFileCoordinator.currentMediaCopyWorkflowID = newValue }
    }
    @Published var syncDraftOriginRoot: URL?
    @Published var syncDraftDestinationRoot: URL?
    @Published private(set) var editingSyncPairID: UUID?
    @Published var completionNotificationsEnabled = true {
        didSet {
            UserDefaults.standard.set(
                completionNotificationsEnabled,
                forKey: DefaultsKey.completionNotificationsEnabled
            )
        }
    }
    @Published var syncOverwriteExisting = true {
        didSet { UserDefaults.standard.set(syncOverwriteExisting, forKey: DefaultsKey.syncOverwriteExisting) }
    }
    @Published var syncDeleteDestinationItems = true {
        didSet {
            UserDefaults.standard.set(
                syncDeleteDestinationItems,
                forKey: DefaultsKey.syncDeleteDestinationItems
            )
            resetFolderSyncPlan()
        }
    }
    @Published var syncDestinationLayout: SyncDestinationLayout = .originSubfolder {
        didSet {
            UserDefaults.standard.set(
                syncDestinationLayout.rawValue,
                forKey: DefaultsKey.syncDestinationLayout
            )
            resetFolderSyncPlan()
        }
    }
    @Published var syncFileFilter: SyncFileFilter = .all {
        didSet {
            UserDefaults.standard.set(syncFileFilter.rawValue, forKey: DefaultsKey.syncFileFilter)
            resetFolderSyncPlan()
        }
    }
    @Published var syncCustomFileExtensions = "" {
        didSet {
            UserDefaults.standard.set(
                syncCustomFileExtensions,
                forKey: DefaultsKey.syncCustomFileExtensions
            )
            if syncFileFilter == .custom {
                resetFolderSyncPlan()
            }
        }
    }
    @Published var syncAutoSyncEnabled = true {
        didSet {
            UserDefaults.standard.set(syncAutoSyncEnabled, forKey: DefaultsKey.syncAutoSyncEnabled)
            configureFolderSyncWatcher()
        }
    }
    @Published private(set) var syncFolderPairs: [SyncFolderPair] = [] {
        didSet {
            guard !isUpdatingSyncPairStatus else { return }
            persistSyncFolderPairs()
            configureFolderSyncWatcher()
        }
    }
    @Published private(set) var syncPlan: FolderSyncPlan?
    @Published private(set) var syncScannedOperationCount = 0
    @Published private(set) var syncScannedCopyCount = 0
    @Published private(set) var syncScannedDeleteCount = 0
    @Published private(set) var syncScannedTotalSize: Int64 = 0
    @Published private(set) var syncProgress: FolderSyncProgress?
    @Published private(set) var isSyncScanning = false
    @Published private(set) var isSyncing = false
    @Published private(set) var isFolderSyncWatching = false
    @Published private(set) var currentSyncPairID: UUID?
    private var mediaRenameUndoStack: [MediaRenameHistoryTransaction] {
        get { mediaFileCoordinator.mediaRenameUndoStack }
        set { mediaFileCoordinator.mediaRenameUndoStack = newValue }
    }
    private var mediaRenameRedoStack: [MediaRenameHistoryTransaction] {
        get { mediaFileCoordinator.mediaRenameRedoStack }
        set { mediaFileCoordinator.mediaRenameRedoStack = newValue }
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

    var mediaRenameOperation: MediaRenameOperation {
        get { mediaFileCoordinator.mediaRenameOperation }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameOperation
            mediaFileCoordinator.mediaRenameOperation = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenamePattern: String {
        get { mediaFileCoordinator.mediaRenamePattern }
        set {
            let oldValue = mediaFileCoordinator.mediaRenamePattern
            mediaFileCoordinator.mediaRenamePattern = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameFindText: String {
        get { mediaFileCoordinator.mediaRenameFindText }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameFindText
            mediaFileCoordinator.mediaRenameFindText = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameReplacementText: String {
        get { mediaFileCoordinator.mediaRenameReplacementText }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameReplacementText
            mediaFileCoordinator.mediaRenameReplacementText = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameIsCaseSensitive: Bool {
        get { mediaFileCoordinator.mediaRenameIsCaseSensitive }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameIsCaseSensitive
            mediaFileCoordinator.mediaRenameIsCaseSensitive = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameAddedText: String {
        get { mediaFileCoordinator.mediaRenameAddedText }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameAddedText
            mediaFileCoordinator.mediaRenameAddedText = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameTextPlacement: MediaRenameTextPlacement {
        get { mediaFileCoordinator.mediaRenameTextPlacement }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameTextPlacement
            mediaFileCoordinator.mediaRenameTextPlacement = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameCaseStyle: MediaRenameCaseStyle {
        get { mediaFileCoordinator.mediaRenameCaseStyle }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameCaseStyle
            mediaFileCoordinator.mediaRenameCaseStyle = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameSort: MediaRenameSort {
        get { mediaFileCoordinator.mediaRenameSort }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameSort
            mediaFileCoordinator.mediaRenameSort = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameStartIndex: Int {
        get { mediaFileCoordinator.mediaRenameStartIndex }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameStartIndex
            mediaFileCoordinator.mediaRenameStartIndex = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameIndexStep: Int {
        get { mediaFileCoordinator.mediaRenameIndexStep }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameIndexStep
            mediaFileCoordinator.mediaRenameIndexStep = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
    }
    var mediaRenameIndexPadding: Int {
        get { mediaFileCoordinator.mediaRenameIndexPadding }
        set {
            let oldValue = mediaFileCoordinator.mediaRenameIndexPadding
            mediaFileCoordinator.mediaRenameIndexPadding = newValue
            handleMediaRenameSettingChanged(from: oldValue, to: newValue)
        }
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

    @Published var confirmBeforeEncoding = true {
        didSet {
            UserDefaults.standard.set(confirmBeforeEncoding, forKey: DefaultsKey.confirmBeforeEncoding)
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

    private var restorePlanTask: Task<Void, Never>?
    private var restoreApplyTask: Task<Void, Never>?
    private var isUpdatingSyncPairStatus = false
    private var isLoadingPersistedSettings = false
    private let securityScopes = SecurityScopeManager()
    private let bookmarks = BookmarkStore()
    private var cancellables: Set<AnyCancellable> = []

    private lazy var encodingCoordinator = EncodingCoordinator(
        getJobs: { [weak self] in
            self?.jobs ?? []
        },
        setJobs: { [weak self] jobs in
            self?.jobs = jobs
        },
        setEncodingState: { [weak self] isEncoding in
            self?.isEncoding = isEncoding
        },
        setStatusMessage: { [weak self] message in
            self?.statusMessage = message
        },
        releaseScopes: { [weak self] in
            self?.securityScopes.stopEncoding()
        },
        notifyCompletion: { [weak self] title, body in
            self?.notifyCompletionIfNeeded(title: title, body: body)
        }
    )

    private lazy var folderSyncCoordinator = FolderSyncCoordinator(
        getIsBusy: { [weak self] in
            self?.isFolderSyncBusy ?? false
        },
        setPlan: { [weak self] plan in
            self?.syncPlan = plan
        },
        setScannedCounts: { [weak self] operations, copies, deletes, size in
            self?.syncScannedOperationCount = operations
            self?.syncScannedCopyCount = copies
            self?.syncScannedDeleteCount = deletes
            self?.syncScannedTotalSize = size
        },
        setProgress: { [weak self] progress in
            self?.syncProgress = progress
        },
        setCurrentPair: { [weak self] pairID in
            self?.currentSyncPairID = pairID
        },
        setScanning: { [weak self] isScanning in
            self?.isSyncScanning = isScanning
        },
        setSyncing: { [weak self] isSyncing in
            self?.isSyncing = isSyncing
        },
        setWatching: { [weak self] isWatching in
            self?.isFolderSyncWatching = isWatching
        },
        setStatusMessage: { [weak self] message in
            self?.statusMessage = message
        },
        markPair: { [weak self] id, state, message, lastSyncedAt in
            self?.markSyncPair(id, state: state, message: message, lastSyncedAt: lastSyncedAt)
        },
        collisionMessage: { [weak self] pairs in
            self?.syncDestinationCollisionMessage(for: pairs)
        },
        prepareFileAccess: { [weak self] pairs, triggeredAutomatically in
            self?.prepareFolderSyncFileAccess(
                for: pairs,
                triggeredAutomatically: triggeredAutomatically
            )
        },
        validateFolders: { [weak self] origin, destination, showsAlert in
            self?.validateSyncFolders(
                originRoot: origin,
                destinationRoot: destination,
                showsAlert: showsAlert
            ) ?? false
        },
        releaseScopes: { [weak self] in
            self?.securityScopes.stopSync()
        },
        notifyCompletion: { [weak self] title, body in
            self?.notifyCompletionIfNeeded(title: title, body: body)
        },
        makeConfiguration: { [weak self] in
            self?.folderSyncRunConfiguration ?? .empty
        }
    )

    private lazy var mediaFileCoordinator = MediaFileCoordinator(
        setStatusMessage: { [weak self] message in
            self?.statusMessage = message
        },
        validateFolders: { [weak self] sourceRoot, destinationRoot in
            self?.validateMediaCopyFolders(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            ) ?? false
        },
        promptConflictResolution: { [weak self] plans in
            self?.promptMediaCopyConflictResolution(for: plans)
        },
        promptTrash: { [weak self] itemCount, totalSize, sourceRootCount, filter, selectedExtensions, fileNameFilter in
            self?.confirmFilteredMediaTrash(
                itemCount: itemCount,
                totalSize: totalSize,
                sourceRootCount: sourceRootCount,
                filter: filter,
                selectedExtensions: selectedExtensions,
                fileNameFilter: fileNameFilter
            ) ?? false
        },
        promptRename: { [weak self] itemCount, unchangedCount in
            self?.confirmMediaRename(itemCount: itemCount, unchangedCount: unchangedCount) ?? false
        },
        promptRenameHistory: { [weak self] transaction, direction in
            self?.confirmMediaRenameHistoryAction(transaction, direction: direction) ?? false
        },
        recordPendingTrashIntents: { [weak self] items in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try self.recordPendingTrashIntents(for: items)
        },
        moveTrashItemAndRecord: { [weak self] item, pendingRecord in
            guard let self else { throw CocoaError(.fileNoSuchFile) }
            return try self.moveItemToTrashAndRecord(item, pendingRecord: pendingRecord)
        },
        removePendingTrashRecords: { [weak self] ids in
            try self?.removePendingTrashRecords(ids: ids)
        },
        removePendingTrashRecordIfOriginalStillExists: { [weak self] record in
            self?.removePendingTrashRecordIfOriginalStillExists(record)
        },
        removeInputsAndResetJobs: { [weak self] movedPaths in
            self?.inputs.removeAll { movedPaths.contains($0.url.standardizedFileURL.path) }
            self?.jobs.removeAll()
            self?.jobStateFilter = nil
        },
        resetJobsForMediaMutation: { [weak self] in
            self?.jobs.removeAll()
            self?.jobStateFilter = nil
        },
        persistRenameHistory: { [weak self] in
            self?.persistMediaRenameHistory()
        },
        notifyCompletion: { [weak self] title, body in
            self?.notifyCompletionIfNeeded(title: title, body: body)
        }
    )

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

    var startConfirmationContext: String {
        switch encodingWorkflow {
        case .audio:
            "When enabled, Start shows the planned output route, overwrite conflicts, FFmpeg thread count, and audio-specific warnings before running."
        case .video:
            "When enabled, Start shows the planned output route, overwrite conflicts, HEVC preset/container, scale mode, audio handling, and pipeline settings before running."
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

    var isFolderSyncBusy: Bool {
        isSyncScanning || isSyncing
    }

    var isMenuBarActivityActive: Bool {
        isEncoding || isMediaCopyBusy || isFolderSyncBusy || isRestorePlanning || isRestoringFromPlan
            || isFolderSyncWatching
    }

    var menuBarActivityTitle: String {
        if isEncoding {
            return "Encoding in progress"
        }

        if isMediaCopyScanning {
            return "Scanning files"
        }

        if isMediaCopying {
            return "Copying files"
        }

        if isMediaDeleting {
            return "Moving files to Trash"
        }

        if isMediaRenaming {
            return "Renaming files"
        }

        if isSyncScanning {
            return "Scanning sync folders"
        }

        if isSyncing {
            return "Syncing folders"
        }

        if isRestorePlanning {
            return "Building restore plan"
        }

        if isRestoringFromPlan {
            return "Restoring files"
        }

        if isFolderSyncWatching {
            let pairCount = syncEnabledPairCount
            let pairLabel = pairCount == 1 ? "pair" : "pairs"
            return "Sync watching \(pairCount) \(pairLabel)"
        }

        return "GPhil Coder active"
    }

    var isQuitBlockedByActiveProcess: Bool {
        isEncoding || isMediaCopyBusy || isFolderSyncBusy || isRestorePlanning || isRestoringFromPlan
    }

    var activeProcessQuitBlockedMessage: String {
        if isEncoding {
            return "Encoding is still running. Cancel encoding or wait for it to finish before closing GPhil Coder."
        }

        if isMediaCopyBusy {
            return "A file management operation is still running. Cancel it or wait for it to finish before closing GPhil Coder."
        }

        if isFolderSyncBusy {
            return "A folder sync is still running. Cancel it or wait for it to finish before closing GPhil Coder."
        }

        if isRestorePlanning {
            return "A restore search is still running. Stop it or wait for it to finish before closing GPhil Coder."
        }

        if isRestoringFromPlan {
            return "Files are still being restored. Wait for the restore operation to finish before closing GPhil Coder."
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

    var canClearMediaCopySources: Bool {
        !mediaCopySourceRoots.isEmpty && !isMediaCopyBusy
    }

    var canAddSyncFolderPair: Bool {
        syncDraftOriginRoot != nil && syncDraftDestinationRoot != nil && !isFolderSyncBusy
    }

    var canSaveSyncFolderPairs: Bool {
        !syncFolderPairs.isEmpty && !isFolderSyncBusy
    }

    var canLoadSyncFolderPairs: Bool {
        !isFolderSyncBusy
    }

    var isEditingSyncFolderPair: Bool {
        editingSyncPairID != nil
    }

    var syncFolderPairSubmitTitle: String {
        isEditingSyncFolderPair ? "Save pair" : "Add pair"
    }

    var canRunFolderSync: Bool {
        syncFolderPairs.contains { $0.isEnabled } && syncHasSelectedFileTypes && !isFolderSyncBusy
    }

    var syncPairCount: Int {
        syncFolderPairs.count
    }

    var syncEnabledPairCount: Int {
        syncFolderPairs.filter(\.isEnabled).count
    }

    var syncPendingOperationCount: Int {
        syncScannedOperationCount
    }

    var syncPendingCopyCount: Int {
        syncScannedCopyCount
    }

    var syncPendingDeleteCount: Int {
        syncScannedDeleteCount
    }

    var syncPendingTotalSize: Int64 {
        syncScannedTotalSize
    }

    var syncPreviewItems: [FolderSyncOperation] {
        syncPlan?.operations ?? []
    }

    var syncDestinationLayoutOptions: [SyncDestinationLayout] {
        SyncDestinationLayout.allCases
    }

    var syncFileFilterOptions: [SyncFileFilter] {
        SyncFileFilter.allCases
    }

    var syncDestinationLayoutDetail: String {
        syncDestinationLayout.detail
    }

    var syncFileFilterDetail: String {
        syncFileFilter.detail
    }

    var syncFileFilterSummary: String {
        switch syncFileFilter {
        case .all:
            return "All files and folders"
        case .audio:
            return MediaFileFilter.audio.readableExtensionList()
        case .video:
            return MediaFileFilter.video.readableExtensionList()
        case .custom:
            let extensions = syncSelectedFileExtensions ?? []
            guard !extensions.isEmpty else { return "No extensions selected" }
            return extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
        }
    }

    var syncHasSelectedFileTypes: Bool {
        syncFileFilter != .custom || !(syncSelectedFileExtensions ?? []).isEmpty
    }

    var syncDraftOriginTitle: String {
        syncDraftOriginRoot?.path(percentEncoded: false) ?? "No origin folder selected"
    }

    var syncDraftDestinationTitle: String {
        syncDraftDestinationRoot?.path(percentEncoded: false) ?? "No destination folder selected"
    }

    var syncWatcherStatusTitle: String {
        guard syncAutoSyncEnabled else { return "Auto-sync paused" }
        guard syncEnabledPairCount > 0 else { return "No watched pairs" }
        return "Watching \(syncEnabledPairCount) pair\(syncEnabledPairCount == 1 ? "" : "s")"
    }

    func effectiveSyncDestinationPath(for pair: SyncFolderPair) -> String {
        effectiveSyncDestinationRoot(for: pair)
            .path(percentEncoded: false)
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
        mediaFileCoordinator.primaryMediaCopySourceRoot
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
        mediaFileCoordinator.currentMediaCopySelectedExtensions
    }

    private var currentMediaFileNameFilter: MediaFileNameFilter {
        mediaFileCoordinator.currentMediaFileNameFilter
    }

    private var mediaPreviewConfiguration: MediaPreviewConfiguration {
        mediaFileCoordinator.mediaPreviewConfiguration
    }

    private var syncSelectedFileExtensions: Set<String>? {
        switch syncFileFilter {
        case .all:
            return nil
        case .audio:
            return MediaFileFilter.audio.fileExtensions
        case .video:
            return MediaFileFilter.video.fileExtensions
        case .custom:
            return Self.normalizedExtensionSet(from: syncCustomFileExtensions)
        }
    }

    private var folderSyncRunConfiguration: FolderSyncRunConfiguration {
        FolderSyncRunConfiguration(
            pairs: syncFolderPairs,
            destinationLayout: syncDestinationLayout,
            deleteDestinationItems: syncDeleteDestinationItems,
            overwriteExisting: syncOverwriteExisting,
            includedFileExtensions: syncSelectedFileExtensions,
            autoSyncEnabled: !isLoadingPersistedSettings && syncAutoSyncEnabled,
            watchOrigins: syncFolderPairs
                .filter(\.isEnabled)
                .compactMap { directoryURLIfExists(atPath: $0.originPath) },
            previewLimit: Self.syncPreviewLimit
        )
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
        mediaFileCoordinator.mediaCopyHasSelectedExtensionsForCurrentFilter
    }

    private var currentMediaCopySourceRootPaths: [String] {
        mediaFileCoordinator.currentMediaCopySourceRootPaths
    }

    private var mediaFileInventoryMatchesCurrentSources: Bool {
        mediaFileCoordinator.mediaFileInventoryMatchesCurrentSources
    }

    private func currentMediaRenameSettings() -> MediaRenameSettings {
        mediaFileCoordinator.currentMediaRenameSettings()
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
        mediaFileCoordinator.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        loadPersistedSettings()
        refreshFFmpeg()
        refreshNotificationPermission()
        refreshActiveFileManagementPreviewIfNeeded()
        configureFolderSyncWatcher()
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

    func clearDeliveredNotifications() {
        AppNotifier.clearGPhilCoderNotifications { [weak self] in
            self?.statusMessage = "Cleared GPhilCoder notifications."
        }
    }

    func openNotificationSettings() {
        AppNotifier.openNotificationSettings()
        statusMessage =
            "Opened macOS Notification settings. If GPhilCoder is not selected automatically, choose it there and enable notifications."
        refreshNotificationPermission()
    }

    private func notifyCompletionIfNeeded(title: String, body: String) {
        guard completionNotificationsEnabled else { return }
        AppNotifier.notifyIfAppInactive(title: title, body: body)
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

    func addDroppedItems(_ providers: [NSItemProvider]) {
        guard !isEncoding else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let urls = await Self.fileURLs(from: providers)
            guard !urls.isEmpty else {
                self.statusMessage = "Drop files or folders to add them to the queue."
                return
            }

            self.rememberInputDirectory(fromFiles: urls)
            var combined = AddSummary()
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    let summary = self.addFolderURL(url)
                    combined.added += summary.added
                    combined.duplicates += summary.duplicates
                    combined.unsupported += summary.unsupported
                } else {
                    let summary = self.addFileURLs([url])
                    combined.added += summary.added
                    combined.duplicates += summary.duplicates
                    combined.unsupported += summary.unsupported
                }
            }

            self.statusMessage = self.queueAddStatusMessage(for: combined)
        }
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

    func clearMediaCopySources() {
        guard canClearMediaCopySources else { return }
        mediaFileCoordinator.cancelFileNameFilterRefresh()
        mediaCopySourceRoots = []
        mediaFileCoordinator.clearInventory()
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = nil
        mediaCopyProgress = nil
        isMediaRenamePreviewStale = false
        statusMessage = "Cleared file-management source folders."
    }

    func chooseSyncOriginRoot() {
        guard !isFolderSyncBusy else { return }
        if let url = chooseDirectory(
            title: "Choose Sync Origin Folder",
            prompt: "Use Origin",
            initialURL: syncDraftOriginRoot ?? lastInputDirectoryURL()
        ) {
            syncDraftOriginRoot = url
            rememberInputDirectory(url)
            statusMessage = "Sync origin set to \(url.path(percentEncoded: false))."
        }
    }

    func chooseSyncDestinationRoot() {
        guard !isFolderSyncBusy else { return }
        if let url = chooseDirectory(
            title: "Choose Sync Destination Folder",
            prompt: "Use Destination",
            initialURL: syncDraftDestinationRoot ?? syncDraftOriginRoot ?? lastInputDirectoryURL()
        ) {
            syncDraftDestinationRoot = url
            statusMessage = "Sync destination set to \(url.path(percentEncoded: false))."
        }
    }

    func addSyncFolderPair() {
        guard let originRoot = syncDraftOriginRoot,
            let destinationRoot = syncDraftDestinationRoot
        else {
            statusMessage = "Choose origin and destination folders before adding a sync pair."
            return
        }

        let originPath = originRoot.standardizedFileURL.path(percentEncoded: false)
        let destinationPath = destinationRoot.standardizedFileURL.path(percentEncoded: false)
        let candidatePair = SyncFolderPair(
            originPath: originPath,
            destinationPath: destinationPath,
            state: syncAutoSyncEnabled ? .watching : .idle,
            originBookmarkData: bookmarks.bookmarkData(for: originRoot),
            destinationBookmarkData: bookmarks.bookmarkData(for: destinationRoot)
        )

        if let editingSyncPairID {
            guard let index = syncFolderPairs.firstIndex(where: { $0.id == editingSyncPairID }) else {
                cancelEditingSyncFolderPair()
                statusMessage = "The sync pair being edited no longer exists."
                return
            }
            if syncFolderPairs.contains(where: {
                $0.id != editingSyncPairID && $0.originPath == originPath && $0.destinationPath == destinationPath
            }) {
                statusMessage = "That sync pair is already in the list."
                return
            }

            var editedPair = syncFolderPairs[index]
            editedPair.originPath = originPath
            editedPair.destinationPath = destinationPath
            editedPair.state = editedPair.isEnabled
                ? (syncAutoSyncEnabled ? .watching : .idle)
                : .disabled
            editedPair.lastMessage = "Ready to sync."
            editedPair.originBookmarkData = bookmarks.bookmarkData(for: originRoot)
            editedPair.destinationBookmarkData = bookmarks.bookmarkData(for: destinationRoot)

            var editedPairs = syncFolderPairs
            editedPairs[index] = editedPair
            guard validateSyncFolders(
                originRoot: editedPair.originURL,
                destinationRoot: effectiveSyncDestinationRoot(for: editedPair, in: editedPairs)
            ) else {
                return
            }
            guard syncDestinationCollisionMessage(for: editedPairs) == nil else {
                statusMessage =
                    "Another enabled sync pair already targets the same destination folder. Rename one origin folder or choose a different destination."
                return
            }

            syncFolderPairs = editedPairs
            self.editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
            resetFolderSyncPlan()
            statusMessage = "Updated sync pair. Press Sync to run the next mirror pass."
            return
        }

        let nextPairs = syncFolderPairs + [candidatePair]
        guard validateSyncFolders(
            originRoot: candidatePair.originURL,
            destinationRoot: effectiveSyncDestinationRoot(for: candidatePair, in: nextPairs)
        ) else {
            return
        }

        if syncFolderPairs.contains(where: {
            $0.originPath == originPath && $0.destinationPath == destinationPath
        }) {
            statusMessage = "That sync pair is already in the list."
            return
        }

        guard syncDestinationCollisionMessage(for: nextPairs) == nil else {
            statusMessage =
                "Another enabled sync pair already targets the same destination folder. Rename one origin folder or choose a different destination."
            return
        }

        syncFolderPairs.append(candidatePair)
        syncDraftOriginRoot = nil
        syncDraftDestinationRoot = nil
        syncPlan = nil
        syncProgress = nil
        statusMessage = "Added sync pair. Press Sync to run the first mirror pass."
    }

    func editSyncFolderPair(_ pair: SyncFolderPair) {
        guard !isFolderSyncBusy else { return }
        editingSyncPairID = pair.id
        syncDraftOriginRoot = pair.originURL
        syncDraftDestinationRoot = pair.destinationURL
        statusMessage = "Editing sync pair. Change the folders, then save."
    }

    func cancelEditingSyncFolderPair() {
        guard !isFolderSyncBusy else { return }
        editingSyncPairID = nil
        syncDraftOriginRoot = nil
        syncDraftDestinationRoot = nil
        statusMessage = "Sync pair edit cancelled."
    }

    func removeSyncFolderPair(_ pair: SyncFolderPair) {
        guard !isFolderSyncBusy else { return }
        syncFolderPairs.removeAll { $0.id == pair.id }
        if currentSyncPairID == pair.id {
            currentSyncPairID = nil
        }
        if editingSyncPairID == pair.id {
            editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
        }
        statusMessage =
            syncFolderPairs.isEmpty ? "Removed the last sync pair." : "Removed sync pair."
    }

    func setSyncFolderPair(_ pair: SyncFolderPair, enabled: Bool) {
        guard !isFolderSyncBusy,
            let index = syncFolderPairs.firstIndex(where: { $0.id == pair.id })
        else {
            return
        }

        syncFolderPairs[index].isEnabled = enabled
        syncFolderPairs[index].state = enabled
            ? (syncAutoSyncEnabled ? .watching : .idle)
            : .disabled
        syncFolderPairs[index].lastMessage = enabled
            ? "Ready to sync."
            : "Paused. Automatic sync is disabled for this pair."
        statusMessage = enabled ? "Sync pair enabled." : "Sync pair paused."
    }

    func saveSyncFolderPairs() {
        guard canSaveSyncFolderPairs else {
            statusMessage = "Add at least one sync pair before saving a pair list."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Sync Pair List"
        panel.prompt = "Save Pair List"
        panel.allowedContentTypes = [SyncFolderPairListFile.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = syncDraftDestinationRoot ?? syncFolderPairs.first?.destinationURL ?? lastInputDirectoryURL()
        panel.nameFieldStringValue = defaultSyncFolderPairListFileName()

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let url = normalizedSyncFolderPairListFileURL(selectedURL)

        do {
            let data = try SyncFolderPairPersistence.encode(syncFolderPairs)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved \(syncFolderPairs.count) sync pair\(syncFolderPairs.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not save sync pair list: \(error.localizedDescription)"
        }
    }

    func loadSyncFolderPairsFromFile() {
        guard canLoadSyncFolderPairs else { return }

        let panel = NSOpenPanel()
        panel.title = "Load Sync Pair List"
        panel.prompt = "Load Pair List"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [SyncFolderPairListFile.contentType, .json]
        panel.directoryURL = syncDraftDestinationRoot ?? syncFolderPairs.first?.destinationURL ?? lastInputDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let loadedPairs = try normalizedLoadedSyncFolderPairs(from: data)
            guard validateLoadedSyncFolderPairs(loadedPairs) else { return }
            guard confirmReplacingSyncFolderPairs(withCount: loadedPairs.count) else { return }

            syncFolderPairs = loadedPairs
            editingSyncPairID = nil
            syncDraftOriginRoot = nil
            syncDraftDestinationRoot = nil
            resetFolderSyncPlan()
            statusMessage =
                "Loaded \(syncFolderPairs.count) sync pair\(syncFolderPairs.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not load sync pair list: \(error.localizedDescription)"
        }
    }

    func scanFolderSyncPlan() {
        folderSyncCoordinator.scan(configuration: folderSyncRunConfiguration)
    }

    func syncFoldersNow() {
        folderSyncCoordinator.syncNow(configuration: folderSyncRunConfiguration)
    }

    func cancelFolderSync() {
        folderSyncCoordinator.cancel()
    }

    func scanMediaCopyFiles() {
        mediaFileCoordinator.scanCopyFiles()
    }

    func copyFilteredMediaFiles() {
        mediaFileCoordinator.copyFilteredFiles()
    }

    func deleteFilteredMediaFiles() {
        mediaFileCoordinator.deleteFilteredFiles()
    }

    func renameFilteredMediaFiles() {
        mediaFileCoordinator.renameFilteredFiles()
    }

    func undoLastMediaRename() {
        mediaFileCoordinator.runRenameHistoryAction(.undo)
    }

    func redoLastMediaRename() {
        mediaFileCoordinator.runRenameHistoryAction(.redo)
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

        mediaFileCoordinator.runQueuedWorkflows(mediaCopyQueue)
    }

    func cancelMediaCopy() {
        guard isMediaCopyBusy else { return }
        mediaFileCoordinator.cancel()
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        mediaRenameProgressVerb = "renamed"
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        statusMessage = "File management operation cancelled."
    }

    private func resetForMediaCopyCoordinatorRun() {
        mediaCopyPlan = nil
        mediaDeletePlan = nil
        mediaRenamePlan = nil
        isMediaRenamePreviewStale = false
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
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
        mediaFileCoordinator.refreshDeletePreview(configuration: mediaPreviewConfiguration)
    }

    func refreshMediaRenamePreview() {
        mediaFileCoordinator.refreshRenamePreview(configuration: mediaPreviewConfiguration)
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

        mediaFileCoordinator.refreshDeletePreviewIfNeeded(configuration: mediaPreviewConfiguration)
    }

    private func refreshMediaRenamePreviewIfNeeded() {
        guard fileManagementMode == .rename else { return }

        guard !mediaCopySourceRoots.isEmpty, mediaCopyHasSelectedExtensionsForCurrentFilter else {
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            return
        }

        mediaFileCoordinator.refreshRenamePreviewIfNeeded(configuration: mediaPreviewConfiguration)
    }

    private func rebuildMediaRenamePreviewFromInventory() {
        mediaFileCoordinator.rebuildRenamePreviewFromInventory(
            configuration: mediaPreviewConfiguration
        )
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

        if confirmBeforeEncoding {
            guard confirmEncodingPreflight(plannedJobs: plannedJobs, settings: settings) else {
                statusMessage = "Encoding cancelled before starting."
                return
            }
        }

        guard prepareEncodingFileAccess(for: plannedJobs) else { return }

        jobStateFilter = nil

        statusMessage =
            "Encoding \(plannedJobs.count) \(plannedJobs.count == 1 ? "file" : "files") with \(settings.summary)..."

        encodingCoordinator.start(jobs: plannedJobs, settings: settings)
    }

    func cancelEncoding() {
        encodingCoordinator.cancel()
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

    private func prepareFolderSyncFileAccess(
        for pairs: [SyncFolderPair],
        triggeredAutomatically: Bool
    ) -> [SyncFolderPair]? {
        securityScopes.stopSync()

        var preparedPairs = pairs
        startFolderSyncSecurityScopes(for: preparedPairs)

        let pairsMissingBookmarks = preparedPairs.filter {
            $0.originBookmarkData == nil || $0.destinationBookmarkData == nil
        }
        guard !pairsMissingBookmarks.isEmpty else { return preparedPairs }

        guard !triggeredAutomatically else {
            securityScopes.stopSync()
            statusMessage = "Auto-sync skipped because loaded sync pairs need folder access authorization."
            return nil
        }

        guard let grantedRoots = requestFolderSyncAccess(for: pairsMissingBookmarks) else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because folder access was not authorized."
            return nil
        }

        securityScopes.startSync(grantedRoots)
        guard selectedSyncAccessRoots(grantedRoots, cover: pairsMissingBookmarks) else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because the selected folder does not contain every loaded origin and destination."
            return nil
        }

        let grantedBookmarks = grantedRoots.compactMap { root -> (url: URL, data: Data)? in
            guard let data = bookmarks.bookmarkData(for: root) else { return nil }
            return (root, data)
        }

        for index in preparedPairs.indices {
            if preparedPairs[index].originBookmarkData == nil {
                preparedPairs[index].originBookmarkData = bookmarks.bookmarkData(
                    for: preparedPairs[index].originURL,
                    in: grantedBookmarks
                )
            }
            if preparedPairs[index].destinationBookmarkData == nil {
                preparedPairs[index].destinationBookmarkData = bookmarks.bookmarkData(
                    for: preparedPairs[index].destinationURL,
                    in: grantedBookmarks
                )
            }
        }

        let stillMissingBookmarks = preparedPairs.contains {
            $0.originBookmarkData == nil || $0.destinationBookmarkData == nil
        }
        guard !stillMissingBookmarks else {
            securityScopes.stopSync()
            statusMessage = "Folder sync cancelled because GPhilCoder could not save folder authorization."
            return nil
        }

        updateStoredSyncPairs(with: preparedPairs)
        startFolderSyncSecurityScopes(for: preparedPairs)
        return preparedPairs
    }

    private func requestFolderSyncAccess(for pairs: [SyncFolderPair]) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Authorize Sync Folder Access"
        panel.prompt = "Authorize"
        panel.message =
            "GPhilCoder needs permission to read and write the folders loaded from this sync pair list. Choose a parent folder that contains all listed origins and destinations, or choose the individual folders."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = commonFolderSyncAccessRoot(for: pairs) ?? pairs.first?.originURL

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func commonFolderSyncAccessRoot(for pairs: [SyncFolderPair]) -> URL? {
        let paths = pairs.flatMap { pair in
            [SecurityScopeManager.normalizedFilePath(pair.originURL),
             SecurityScopeManager.normalizedFilePath(pair.destinationURL)]
        }
        guard let firstPath = paths.first else { return nil }

        var commonComponents = URL(fileURLWithPath: firstPath, isDirectory: true).pathComponents
        for path in paths.dropFirst() {
            let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
            commonComponents = Array(zip(commonComponents, components).prefix { $0 == $1 }.map(\.0))
            guard !commonComponents.isEmpty else { return nil }
        }

        let commonPath = NSString.path(withComponents: commonComponents)
        return URL(fileURLWithPath: commonPath, isDirectory: true)
    }

    private func selectedSyncAccessRoots(_ roots: [URL], cover pairs: [SyncFolderPair]) -> Bool {
        for pair in pairs {
            guard roots.contains(where: { SecurityScopeManager.containsFileURL(pair.originURL, in: $0) }),
                roots.contains(where: { SecurityScopeManager.containsFileURL(pair.destinationURL, in: $0) })
            else {
                return false
            }
        }
        return true
    }

    /// Resolves each pair's origin/destination bookmarks into security-scoped
    /// URLs and starts accessing them. When macOS reports a bookmark as stale
    /// (folder renamed/moved), the bookmark is re-created from the resolved URL
    /// and the pair is updated so the next launch resolves cleanly.
    private func startFolderSyncSecurityScopes(for pairs: [SyncFolderPair]) {
        var refreshedPairs = pairs
        var anyPairRefreshed = false

        let urls = pairs.flatMap { pair -> [URL] in
            guard let index = refreshedPairs.firstIndex(where: { $0.id == pair.id }) else {
                return [pair.originURL, pair.destinationURL]
            }
            let originURL = bookmarks.resolveSecurityScopedBookmark(
                pair.originBookmarkData,
                fallbackURL: pair.originURL
            ) { resolved in
                if let refreshed = self.bookmarks.bookmarkData(for: resolved) {
                    refreshedPairs[index].originBookmarkData = refreshed
                    anyPairRefreshed = true
                }
            }
            let destinationURL = bookmarks.resolveSecurityScopedBookmark(
                pair.destinationBookmarkData,
                fallbackURL: pair.destinationURL
            ) { resolved in
                if let refreshed = self.bookmarks.bookmarkData(for: resolved) {
                    refreshedPairs[index].destinationBookmarkData = refreshed
                    anyPairRefreshed = true
                }
            }
            return [originURL, destinationURL]
        }

        securityScopes.startSync(urls)
        if anyPairRefreshed {
            updateStoredSyncPairs(with: refreshedPairs)
        }
    }

    private func updateStoredSyncPairs(with preparedPairs: [SyncFolderPair]) {
        guard !preparedPairs.isEmpty else { return }
        var updatedPairs = syncFolderPairs
        for preparedPair in preparedPairs {
            guard let index = updatedPairs.firstIndex(where: { $0.id == preparedPair.id }) else { continue }
            updatedPairs[index] = preparedPair
        }
        syncFolderPairs = updatedPairs
    }

    private func prepareEncodingFileAccess(for plannedJobs: [EncodeJob]) -> Bool {
        securityScopes.stopEncoding()

        let initialRoots = securityScopedRoots(for: plannedJobs)
        securityScopes.startEncoding(initialRoots)

        let outputDirectories = SecurityScopeManager.uniqueURLs(
            plannedJobs.map { $0.outputURL.deletingLastPathComponent() }
        )
        let deniedDirectories = outputDirectories.filter { !securityScopes.canWriteTemporaryFile(in: $0) }
        guard !deniedDirectories.isEmpty else { return true }

        guard let grantedRoots = requestWriteAccess(for: deniedDirectories) else {
            securityScopes.stopEncoding()
            statusMessage = "Encoding cancelled because GPhilCoder does not have permission to write to the output folder."
            return false
        }

        securityScopes.startEncoding(grantedRoots)
        let stillDenied = outputDirectories.filter { !securityScopes.canWriteTemporaryFile(in: $0) }
        guard stillDenied.isEmpty else {
            securityScopes.stopEncoding()
            let names = stillDenied.prefix(3).map { $0.path(percentEncoded: false) }.joined(separator: "\n")
            statusMessage = "GPhilCoder still cannot write to:\n\(names)"
            return false
        }

        return true
    }

    private func securityScopedRoots(for plannedJobs: [EncodeJob]) -> [URL] {
        var urls = plannedJobs.flatMap { job in
            [job.item.url, job.item.sourceRoot, job.outputURL.deletingLastPathComponent()].compactMap { $0 }
        }

        if let exportFolder {
            urls.append(exportFolder)
        }

        return SecurityScopeManager.uniqueURLs(urls)
    }

    private func requestWriteAccess(for directories: [URL]) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Authorize Output Folder Access"
        panel.prompt = "Authorize"
        panel.message =
            "GPhilCoder needs permission to write encoded files to the selected output folder. Choose the source/output folder, or a parent folder that contains all planned outputs."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = directories.first

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
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

    private func defaultSyncFolderPairListFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhilCoder Sync Pairs \(formatter.string(from: Date())).\(SyncFolderPairListFile.fileExtension)"
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

    private func normalizedSyncFolderPairListFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(SyncFolderPairListFile.fileExtension) : url
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

        if let data = defaults.data(forKey: DefaultsKey.trashedSourceRecords) {
            switch VersionedBlob.decodeEnvelope(
                from: data, currentVersion: 1, allowLegacyBareArray: true
            ) as Result<[TrashedSourceRecord], DecodeProblem> {
            case .success(let records):
                trashedSourceRecords = records
            case .failure(.versionMismatch):
                // Leave the blob intact for a newer build to read.
                statusMessage =
                    "Could not read saved trash records — they were saved by a newer version of GPhilCoder and were kept. Restore-from-Trash may be unavailable until you upgrade."
            case .failure(.corrupt):
                preserveCorruptBlob(data, name: "trashed-source-records")
                statusMessage =
                    "Could not read saved trash records — the data appears damaged and was preserved to a backup file. Contact support before relying on Trash restore."
            }
        }
        if let data = defaults.data(forKey: DefaultsKey.mediaRenameHistory) {
            // The rename-history document already carries its own version, so
            // route it through the shared helper to surface a corrupt blob
            // rather than silently discarding undo/redo history.
            let result = VersionedBlob.decode(
                from: data,
                currentVersion: MediaRenameHistoryDocument.currentVersion,
                decodePayload: { data in
                    let document = try JSONDecoder().decode(
                        MediaRenameHistoryDocument.self, from: data
                    )
                    guard document.version == MediaRenameHistoryDocument.currentVersion else {
                        // Re-throw as a version mismatch the envelope check missed
                        // (the document decodes structurally but reports a new version).
                        throw DecodeProblem.versionMismatch(
                            found: document.version,
                            supported: MediaRenameHistoryDocument.currentVersion
                        )
                    }
                    return [document]
                }
            ) as Result<[MediaRenameHistoryDocument], DecodeProblem>
            switch result {
            case .success(let documents):
                if let document = documents.first {
                    mediaRenameUndoStack = Array(
                        document.undoStack.suffix(Self.mediaRenameHistoryLimit)
                    )
                    mediaRenameRedoStack = Array(
                        document.redoStack.suffix(Self.mediaRenameHistoryLimit)
                    )
                }
            case .failure(.versionMismatch):
                statusMessage =
                    "Could not read rename history — it was saved by a newer version of GPhilCoder and was kept."
            case .failure(.corrupt):
                preserveCorruptBlob(data, name: "media-rename-history")
                statusMessage =
                    "Could not read rename history — the data appears damaged and was preserved to a backup file."
            }
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

        if let value = persistedBool(forKey: DefaultsKey.syncOverwriteExisting) {
            syncOverwriteExisting = value
        }
        if let value = persistedBool(forKey: DefaultsKey.syncDeleteDestinationItems) {
            syncDeleteDestinationItems = value
        }
        if let value = persistedBool(forKey: DefaultsKey.syncAutoSyncEnabled) {
            syncAutoSyncEnabled = value
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.syncDestinationLayout),
            let value = SyncDestinationLayout(rawValue: rawValue)
        {
            syncDestinationLayout = value
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.syncFileFilter),
            let value = SyncFileFilter(rawValue: rawValue)
        {
            syncFileFilter = value
        }
        syncCustomFileExtensions =
            defaults.string(forKey: DefaultsKey.syncCustomFileExtensions) ?? ""
        if let value = persistedBool(forKey: DefaultsKey.completionNotificationsEnabled) {
            completionNotificationsEnabled = value
        }
        loadSyncFolderPairs(from: defaults)

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

        if let value = persistedBool(forKey: DefaultsKey.confirmBeforeEncoding) {
            confirmBeforeEncoding = value
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
        mediaFileCoordinator.selectedExtensions(for: filter)
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

    private func validateSyncFolders(
        originRoot: URL,
        destinationRoot: URL,
        showsAlert: Bool = true,
        createsDestinationDirectory: Bool = true
    ) -> Bool {
        let originComponents = originRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let destinationComponents =
            destinationRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard directoryURLIfExists(atPath: originRoot.path) != nil else {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Origin folder is missing",
                    detail: "Choose an existing origin folder before syncing."
                )
            }
            return false
        }

        if createsDestinationDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: destinationRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                if showsAlert {
                    showMediaCopyFolderAlert(
                        message: "Destination folder is unavailable",
                        detail: "GPhilCoder could not create or open the destination folder: \(error.localizedDescription)"
                    )
                }
                return false
            }
        }

        if originComponents == destinationComponents {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Choose different folders",
                    detail:
                        "The sync origin and destination folders are the same. Choose a separate destination folder."
                )
            }
            return false
        }

        if destinationComponents.count > originComponents.count
            && Array(destinationComponents.prefix(originComponents.count)) == originComponents
        {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Destination is inside the origin",
                    detail:
                        "Choose a destination outside the origin tree so sync output is not scanned as new origin content."
                )
            }
            return false
        }

        if originComponents.count > destinationComponents.count
            && Array(originComponents.prefix(destinationComponents.count)) == destinationComponents
        {
            if showsAlert {
                showMediaCopyFolderAlert(
                    message: "Origin is inside the destination",
                    detail:
                        "Choose folders that do not contain each other so deletion mirroring cannot remove the origin tree."
                )
            }
            return false
        }

        return true
    }

    private func validateLoadedSyncFolderPairs(_ pairs: [SyncFolderPair]) -> Bool {
        var seenPairs = Set<String>()
        for pair in pairs {
            let key = "\(pair.originPath)\n\(pair.destinationPath)"
            guard seenPairs.insert(key).inserted else {
                statusMessage =
                    "Could not load sync pair list: it contains duplicate origin and destination folders."
                return false
            }

            guard validateSyncFolders(
                originRoot: pair.originURL,
                destinationRoot: effectiveSyncDestinationRoot(for: pair, in: pairs),
                showsAlert: false,
                createsDestinationDirectory: false
            ) else {
                statusMessage =
                    "Could not load sync pair list: one or more origin folders are missing or folder paths are nested unsafely."
                return false
            }
        }

        if let collisionMessage = syncDestinationCollisionMessage(for: pairs) {
            statusMessage = "Could not load sync pair list: \(collisionMessage)"
            return false
        }

        return true
    }

    private func confirmReplacingSyncFolderPairs(withCount newPairCount: Int) -> Bool {
        guard !syncFolderPairs.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "Replace current sync pairs?"
        alert.informativeText =
            "Loading this file will replace the current \(syncFolderPairs.count) sync pair\(syncFolderPairs.count == 1 ? "" : "s") with \(newPairCount) pair\(newPairCount == 1 ? "" : "s")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func effectiveSyncDestinationRoot(
        for pair: SyncFolderPair,
        in pairs: [SyncFolderPair]? = nil
    ) -> URL {
        let resolutionPairs = pairs ?? syncDestinationResolutionPairs(for: pair)
        return pair.effectiveDestinationURL(
            layout: syncDestinationLayout,
            allPairs: resolutionPairs
        )
    }

    private func syncDestinationResolutionPairs(for pair: SyncFolderPair) -> [SyncFolderPair] {
        let enabledPairs = syncFolderPairs.filter(\.isEnabled)
        if pair.isEnabled {
            return enabledPairs
        }
        return enabledPairs + [pair]
    }

    private func syncDestinationCollisionMessage(for pairs: [SyncFolderPair]) -> String? {
        var seenPaths: [String: SyncFolderPair] = [:]
        for pair in pairs where pair.isEnabled {
            let target = effectiveSyncDestinationRoot(for: pair, in: pairs)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if let existing = seenPaths[target], existing.id != pair.id {
                return
                    "Sync pairs \"\(existing.originURL.lastPathComponent)\" and \"\(pair.originURL.lastPathComponent)\" target the same destination folder. Use different destination folders or rename one origin folder."
            }
            seenPaths[target] = pair
        }
        return nil
    }

    private func resetFolderSyncPlan() {
        guard !isLoadingPersistedSettings, !isFolderSyncBusy else { return }
        syncPlan = nil
        syncScannedOperationCount = 0
        syncScannedCopyCount = 0
        syncScannedDeleteCount = 0
        syncScannedTotalSize = 0
        syncProgress = nil
    }

    private func markSyncPair(
        _ id: UUID,
        state: SyncPairState,
        message: String,
        lastSyncedAt: Date? = nil
    ) {
        guard let index = syncFolderPairs.firstIndex(where: { $0.id == id }) else { return }
        isUpdatingSyncPairStatus = true
        defer {
            isUpdatingSyncPairStatus = false
            if lastSyncedAt != nil {
                persistSyncFolderPairs()
            }
        }
        syncFolderPairs[index].state = syncFolderPairs[index].isEnabled ? state : .disabled
        syncFolderPairs[index].lastMessage = message
        if let lastSyncedAt {
            syncFolderPairs[index].lastSyncedAt = lastSyncedAt
        }
    }

    private func configureFolderSyncWatcher() {
        folderSyncCoordinator.configureWatcher(configuration: folderSyncRunConfiguration)
    }

    private func persistSyncFolderPairs() {
        guard !isLoadingPersistedSettings else { return }
        do {
            let data = try SyncFolderPairPersistence.encode(syncFolderPairs)
            UserDefaults.standard.set(data, forKey: DefaultsKey.syncFolderPairs)
        } catch {
            statusMessage = "Could not save sync pairs: \(error.localizedDescription)"
        }
    }

    private func loadSyncFolderPairs(from defaults: UserDefaults) {
        guard let data = defaults.data(forKey: DefaultsKey.syncFolderPairs) else {
            return
        }

        do {
            syncFolderPairs = try normalizedLoadedSyncFolderPairs(from: data)
        } catch {
            statusMessage = "Could not read saved sync pairs: \(error.localizedDescription)"
        }
    }

    private func normalizedLoadedSyncFolderPairs(from data: Data) throws -> [SyncFolderPair] {
        let pairs: [SyncFolderPair]
        pairs = try SyncFolderPairPersistence.decode(data)

        return pairs.map { pair in
            var pair = pair
            if !pair.isEnabled {
                pair.state = .disabled
            } else {
                pair.state = syncAutoSyncEnabled ? .watching : .idle
            }
            return pair
        }
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
        mediaFileCoordinator.cancelFileNameFilterRefresh()
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        guard !isLoadingPersistedSettings else { return }

        if mediaCopySourceRoots.isEmpty {
            mediaFileCoordinator.clearInventory()
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
        mediaFileCoordinator.cancelFileNameFilterRefresh()
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
        mediaFileCoordinator.scheduleFileNameFilterPreviewRefresh(
            nanoseconds: Self.mediaFileNameFilterDebounceNanoseconds,
            refresh: { [weak self] in self?.refreshActiveFileManagementPreviewIfNeeded() },
            isBusy: { [weak self] in self?.isMediaCopyBusy ?? true }
        )
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

        if let data = try? VersionedBlob.encode(trashedSourceRecords, currentVersion: 1) {
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
        let document = MediaRenameSettingsDocument(settings: settings)
        if let data = try? JSONEncoder().encode(document) {
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
        guard let data = defaults.data(forKey: DefaultsKey.mediaRenameSettings) else { return }

        // Rename settings are a single struct, not an array. Wrap a decode
        // through the shared helper so a corrupt blob surfaces instead of
        // silently reverting the user's last-used rename configuration.
        let result = VersionedBlob.decode(
            from: data,
            currentVersion: MediaRenameSettingsDocument.currentVersion,
            decodePayload: { data in
                [try JSONDecoder().decode(MediaRenameSettingsDocument.self, from: data).settings]
            },
            legacyBareArray: { data in
                // Legacy shape was a bare MediaRenameSettings struct.
                guard let settings = try? JSONDecoder().decode(
                    MediaRenameSettings.self, from: data
                ) else { return nil }
                return [settings]
            }
        ) as Result<[MediaRenameSettings], DecodeProblem>

        switch result {
        case .success(let settings) where !settings.isEmpty:
            applyMediaRenameSettings(settings[0])
        case .failure(.versionMismatch):
            statusMessage =
                "Could not read rename settings — they were saved by a newer version of GPhilCoder and were kept."
        case .failure(.corrupt):
            preserveCorruptBlob(data, name: "media-rename-settings")
            statusMessage =
                "Could not read rename settings — the data appears damaged and was preserved to a backup file."
        case .success:
            break
        }
    }

    private func applyMediaRenameSettings(_ settings: MediaRenameSettings) {
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
        guard let data = try? Data(contentsOf: url) else { return }

        // The emergency journal is the last-resort record of files about to be
        // moved to Trash. A corrupt blob must surface, not vanish — otherwise
        // the user could lose the ability to recover files this app deleted.
        switch VersionedBlob.decodeEnvelope(
            from: data, currentVersion: 1, allowLegacyBareArray: true
        ) as Result<[PendingTrashSourceRecord], DecodeProblem> {
        case .success(let records):
            pendingTrashSourceRecords = records
        case .failure(.versionMismatch):
            statusMessage =
                "Could not read the trash emergency journal — it was saved by a newer version of GPhilCoder and was kept."
        case .failure(.corrupt):
            preserveCorruptBlob(data, name: "trash-emergency-journal")
            statusMessage =
                "Could not read the trash emergency journal — the data appears damaged and was preserved to a backup file. If you recently moved files to Trash, contact support before clearing it."
        }
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

        let data = try VersionedBlob.encode(records, currentVersion: 1)
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

    /// Preserves a corrupt persisted blob to a timestamped `.corrupt` sidecar
    /// in Application Support so the user (or support) can recover it later.
    /// Used when a decode surfaces `.corrupt` for safety-critical payloads
    /// (trash records, rename history, the trash emergency journal).
    private func preserveCorruptBlob(_ data: Data, name: String) {
        do {
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
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let sidecar = directoryURL.appendingPathComponent(
                "\(name)-\(timestamp).corrupt",
                isDirectory: false
            )
            try data.write(to: sidecar, options: [.atomic])
        } catch {
            // Best-effort: surfacing already happened via statusMessage. Do not
            // raise a further error from this recovery path.
        }
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

    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await fileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }

                if let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    continuation.resume(returning: url)
                    return
                }

                if let text = item as? String,
                    let url = URL(string: text)
                {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func queueAddStatusMessage(for summary: AddSummary) -> String {
        guard summary.added > 0, !inputs.isEmpty else {
            return summary.message
        }

        return "\(summary.message) \(activeInputs.count) of \(inputs.count) queued file\(inputs.count == 1 ? "" : "s") active."
    }

    func addFileURLs(_ urls: [URL]) -> AddSummary {
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

    private static func normalizedExtensionSet(from text: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: ",; \n\t")
        return Set(
            text.components(separatedBy: separators)
                .compactMap { token in
                    let normalized = token
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        .lowercased()
                    return normalized.isEmpty ? nil : normalized
                }
        )
    }
}

private struct QueueLoadResult {
    var items: [AudioInputItem] = []
    var missing = 0
    var unsupported = 0
    var duplicates = 0
}
