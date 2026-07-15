import AppKit
import Combine
import Foundation
import GPhilCoderCore
import UniformTypeIdentifiers

@MainActor
final class EncoderViewModel: ObservableObject {
    typealias DefaultsKey = SettingsPersistence.Key

    private static let mediaRenameHistoryLimit = 20
    private static let mediaPreviewLimit = 300
    private static let mediaFileNameFilterDebounceNanoseconds: UInt64 = 400_000_000
    static let syncPreviewLimit = 300

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

    enum SyncFolderPairListFile {
        static let fileExtension = "gphilcodersync"

        static var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .json
        }
    }

    private enum TrashEmergencyJournal {
        static let directoryName = "GPhilCoder"
        static let fileName = "trash-emergency-journal.json"
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
    @Published var statusMessage = "Add audio or video files to begin."
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
            settingsPersistence.set(newValue.rawValue, forKey: DefaultsKey.fileManagementMode)
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
    var mediaCopyDestinationLayout: MediaCopyDestinationLayout {
        get { mediaFileCoordinator.mediaCopyDestinationLayout }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyDestinationLayout
            mediaFileCoordinator.mediaCopyDestinationLayout = newValue
            settingsPersistence.set(newValue.rawValue, forKey: DefaultsKey.mediaCopyDestinationLayout)
            invalidateMediaCopyPlanIfChanged(from: oldValue, to: newValue)
        }
    }
    var mediaCopyFilter: MediaFileFilter {
        get { mediaFileCoordinator.mediaCopyFilter }
        set {
            let oldValue = mediaFileCoordinator.mediaCopyFilter
            mediaFileCoordinator.mediaCopyFilter = newValue
            settingsPersistence.set(newValue.rawValue, forKey: DefaultsKey.mediaCopyFilter)
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
            settingsPersistence.set(newValue, forKey: DefaultsKey.mediaFileNameFilterQuery)
            handleMediaFileNameFilterChanged(
                from: oldValue.trimmingCharacters(in: .whitespacesAndNewlines),
                to: newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
    var mediaCopyPlan: MediaCopyBatchPlan? {
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
    var isMediaCopyFinalizing: Bool {
        get { mediaFileCoordinator.isMediaCopyFinalizing }
        set { mediaFileCoordinator.isMediaCopyFinalizing = newValue }
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
    @Published var editingSyncPairID: UUID?
    @Published var completionNotificationsEnabled = true {
        didSet {
            settingsPersistence.set(
                completionNotificationsEnabled,
                forKey: DefaultsKey.completionNotificationsEnabled
            )
        }
    }
    @Published var syncOverwriteExisting = true {
        didSet {
            settingsPersistence.set(syncOverwriteExisting, forKey: DefaultsKey.syncOverwriteExisting)
            resetFolderSyncPlan()
        }
    }
    @Published var syncDeleteDestinationItems = false {
        didSet {
            settingsPersistence.set(
                syncDeleteDestinationItems,
                forKey: DefaultsKey.syncDeleteDestinationItems
            )
            resetFolderSyncPlan()
        }
    }
    @Published var syncDestinationLayout: SyncDestinationLayout = .originSubfolder {
        didSet {
            settingsPersistence.set(
                syncDestinationLayout.rawValue,
                forKey: DefaultsKey.syncDestinationLayout
            )
            resetFolderSyncPlan()
        }
    }
    @Published var syncFileFilter: SyncFileFilter = .all {
        didSet {
            settingsPersistence.set(syncFileFilter.rawValue, forKey: DefaultsKey.syncFileFilter)
            resetFolderSyncPlan()
        }
    }
    @Published var syncCustomFileExtensions = "" {
        didSet {
            settingsPersistence.set(
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
            settingsPersistence.set(syncAutoSyncEnabled, forKey: DefaultsKey.syncAutoSyncEnabled)
            configureFolderSyncWatcher()
        }
    }
    @Published var syncSafetyMigrationNeedsAcknowledgement = false
    @Published var syncFolderPairs: [SyncFolderPair] = [] {
        didSet {
            guard !isUpdatingSyncPairStatus else { return }
            persistSyncFolderPairs()
            configureFolderSyncWatcher()
        }
    }
    @Published var syncPlan: FolderSyncBatchPlan?
    @Published var syncScannedOperationCount = 0
    @Published var syncScannedCopyCount = 0
    @Published var syncScannedDeleteCount = 0
    @Published var syncScannedTotalSize: Int64 = 0
    @Published var syncProgress: FolderSyncProgress?
    @Published var isSyncScanning = false
    @Published var isSyncing = false
    @Published var isFolderSyncWatching = false
    @Published var syncAutomaticPlanAwaitingReview = false
    @Published var isSyncRecovering = false
    @Published var syncHistory: [FolderSyncHistoryRun] = []
    @Published var syncRecoveryRecords: [FolderSyncRecoveryRecord] = []
    @Published var currentSyncPairID: UUID?
    var folderSyncDestructiveConfirmationHandler = FolderSyncAppKitPromptBoundary.confirmDestructivePlan
    var folderSyncDeletionEnableConfirmationHandler = FolderSyncAppKitPromptBoundary.confirmDeletionEnable
    var folderSyncPairReplacementConfirmationHandler = FolderSyncAppKitPromptBoundary.confirmPairReplacement
    var mediaCopyConflictResolutionHandler: (([MediaCopyBatchPlan]) -> MediaCopyConflictResolution?)?
    var mediaCopyFolderValidationHandler: ((URL, URL) -> Bool)?
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
            settingsPersistence.set(
                selectedInputExtensions.sorted(),
                forKey: DefaultsKey.selectedInputExtensions
            )
        }
    }

    @Published private(set) var selectedVideoInputExtensions: Set<String> = VideoFormat.inputExtensions {
        didSet {
            settingsPersistence.set(
                selectedVideoInputExtensions.sorted(),
                forKey: DefaultsKey.selectedVideoInputExtensions
            )
        }
    }

    @Published var encodingWorkflow: EncodingWorkflow = .audio {
        didSet {
            settingsPersistence.set(
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
        didSet { settingsPersistence.set(outputMode.rawValue, forKey: DefaultsKey.outputMode) }
    }

    @Published var exportFolder: URL? {
        didSet {
            if let exportFolder {
                settingsPersistence.set(
                    exportFolder.standardizedFileURL.path(percentEncoded: false),
                    forKey: DefaultsKey.exportFolderPath)
            } else {
                settingsPersistence.removeObject(forKey: DefaultsKey.exportFolderPath)
            }
        }
    }

    @Published var preserveSubfolders = true {
        didSet {
            settingsPersistence.set(preserveSubfolders, forKey: DefaultsKey.preserveSubfolders)
        }
    }

    @Published var overwriteExisting = false {
        didSet {
            settingsPersistence.set(overwriteExisting, forKey: DefaultsKey.overwriteExisting)
        }
    }

    @Published var confirmBeforeEncoding = true {
        didSet {
            settingsPersistence.set(confirmBeforeEncoding, forKey: DefaultsKey.confirmBeforeEncoding)
        }
    }

    @Published var outputFormat: AudioOutputFormat = .mp3 {
        didSet {
            settingsPersistence.set(outputFormat.rawValue, forKey: DefaultsKey.outputFormat)
        }
    }

    @Published var videoOutputContainer: VideoOutputContainer = .mp4 {
        didSet {
            settingsPersistence.set(
                videoOutputContainer.rawValue,
                forKey: DefaultsKey.videoOutputContainer
            )
        }
    }

    @Published var hevcPreset: HEVCVideoPreset = .balanced1080p {
        didSet {
            settingsPersistence.set(hevcPreset.rawValue, forKey: DefaultsKey.hevcPreset)
            if !isLoadingPersistedSettings {
                videoScaleMode = hevcPreset.defaultScaleMode
            }
        }
    }

    @Published var customVideoBitrateKbps = 8_000 {
        didSet {
            settingsPersistence.set(
                customVideoBitrateKbps,
                forKey: DefaultsKey.customVideoBitrateKbps
            )
        }
    }

    @Published var videoScaleMode: VideoScaleMode = HEVCVideoPreset.balanced1080p.defaultScaleMode {
        didSet {
            settingsPersistence.set(videoScaleMode.rawValue, forKey: DefaultsKey.videoScaleMode)
        }
    }

    @Published var videoAudioMode: VideoAudioMode = .copy {
        didSet {
            settingsPersistence.set(videoAudioMode.rawValue, forKey: DefaultsKey.videoAudioMode)
        }
    }

    @Published var videoHardwareDecodeMode: VideoHardwareDecodeMode = .auto {
        didSet {
            settingsPersistence.set(
                videoHardwareDecodeMode.rawValue,
                forKey: DefaultsKey.videoHardwareDecodeMode
            )
        }
    }

    @Published var mp3Mode: MP3EncodingMode = .vbr {
        didSet { settingsPersistence.set(mp3Mode.rawValue, forKey: DefaultsKey.mp3Mode) }
    }

    @Published var vbrQuality = 2 {
        didSet { settingsPersistence.set(vbrQuality, forKey: DefaultsKey.vbrQuality) }
    }

    @Published var cbrBitrateKbps = 320 {
        didSet { settingsPersistence.set(cbrBitrateKbps, forKey: DefaultsKey.cbrBitrateKbps) }
    }

    @Published var abrBitrateKbps = 192 {
        didSet { settingsPersistence.set(abrBitrateKbps, forKey: DefaultsKey.abrBitrateKbps) }
    }

    @Published var oggMode: OggEncodingOptions.Mode = .bitrate {
        didSet { settingsPersistence.set(oggMode.rawValue, forKey: DefaultsKey.oggMode) }
    }

    @Published var oggQuality = 6 {
        didSet { settingsPersistence.set(oggQuality, forKey: DefaultsKey.oggQuality) }
    }

    @Published var oggBitrateKbps = 256 {
        didSet { settingsPersistence.set(oggBitrateKbps, forKey: DefaultsKey.oggBitrateKbps) }
    }

    @Published var opusRateMode: OpusEncodingOptions.RateMode = .vbr {
        didSet {
            settingsPersistence.set(opusRateMode.rawValue, forKey: DefaultsKey.opusRateMode)
        }
    }

    @Published var opusBitrateKbps = 192 {
        didSet { settingsPersistence.set(opusBitrateKbps, forKey: DefaultsKey.opusBitrateKbps) }
    }

    @Published var flacCompressionLevel = 8 {
        didSet {
            settingsPersistence.set(
                flacCompressionLevel, forKey: DefaultsKey.flacCompressionLevel)
        }
    }

    @Published var splitOversizedMultichannel = true {
        didSet {
            settingsPersistence.set(
                splitOversizedMultichannel,
                forKey: DefaultsKey.splitOversizedMultichannel
            )
        }
    }

    @Published var parallelJobs = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) {
        didSet { settingsPersistence.set(parallelJobs, forKey: DefaultsKey.parallelJobs) }
    }

    @Published var ffmpegThreads = 0 {
        didSet { settingsPersistence.set(ffmpegThreads, forKey: DefaultsKey.ffmpegThreads) }
    }

    @Published var ffmpegSourcePreference: FFmpegSourcePreference = .bundled {
        didSet {
            settingsPersistence.set(
                ffmpegSourcePreference.rawValue,
                forKey: DefaultsKey.ffmpegSourcePreference
            )
            if oldValue != ffmpegSourcePreference {
                refreshFFmpeg()
            }
        }
    }

    var isUpdatingSyncPairStatus = false
    var isLoadingPersistedSettings = false
    let settingsPersistence = SettingsPersistence()
    let securityScopes = SecurityScopeManager()
    let bookmarks = BookmarkStore()
    let folderSyncServices: FolderSyncServices?
    private let folderSyncServicesError: String?
    private var cancellables: Set<AnyCancellable> = []

    lazy var folderSyncRunExecutor: FolderSyncRunExecutor? =
        folderSyncServices.map(FolderSyncRunExecutor.init)

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

    lazy var folderSyncCoordinator = makeFolderSyncCoordinator()

    lazy var mediaFileCoordinator = MediaFileCoordinator(
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

    private lazy var restoreCoordinator = RestoreCoordinator(
        setRecords: { [weak self] records in
            self?.restorePlanRecords = records
        },
        setLiveCounts: { [weak self] counts in
            self?.restorePlanLiveCounts = counts
        },
        setLiveUnresolvedItems: { [weak self] items in
            self?.restorePlanLiveUnresolvedItems = items
        },
        setScanSummary: { [weak self] summary in
            self?.restorePlanScanSummary = summary
        },
        setProgress: { [weak self] progress in
            self?.restorePlanProgress = progress
        },
        setPlanning: { [weak self] isPlanning in
            self?.isRestorePlanning = isPlanning
        },
        setRestoring: { [weak self] isRestoring in
            self?.isRestoringFromPlan = isRestoring
        },
        setStoppedWithPartialResults: { [weak self] stopped in
            self?.restorePlanStoppedWithPartialResults = stopped
        },
        setStatusMessage: { [weak self] message in
            self?.statusMessage = message
        },
        appendRestoredFileURLs: { [weak self] urls in
            self?.appendRestoredFileURLs(urls)
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
        isMediaCopyScanning || isMediaCopying || isMediaCopyFinalizing
            || isMediaDeleting || isMediaRenaming
    }

    var canCancelMediaCopy: Bool { isMediaCopyBusy && !isMediaCopyFinalizing }

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

        if isMediaCopyFinalizing {
            return "Finalizing file copy"
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

        return "GPhil MediaFlow active"
    }

    var isQuitBlockedByActiveProcess: Bool {
        isEncoding || isMediaCopyBusy || isFolderSyncBusy || isRestorePlanning || isRestoringFromPlan
    }

    var activeProcessQuitBlockedMessage: String {
        if isEncoding {
            return "Encoding is still running. Cancel encoding or wait for it to finish before closing GPhil MediaFlow."
        }

        if isMediaCopyBusy {
            return "A file management operation is still running. Cancel it or wait for it to finish before closing GPhil MediaFlow."
        }

        if isFolderSyncBusy {
            return "A folder sync is still running. Cancel it or wait for it to finish before closing GPhil MediaFlow."
        }

        if isRestorePlanning {
            return "A restore search is still running. Stop it or wait for it to finish before closing GPhil MediaFlow."
        }

        if isRestoringFromPlan {
            return "Files are still being restored. Wait for the restore operation to finish before closing GPhil MediaFlow."
        }

        return "An active process is still running. Wait for it to finish before closing GPhil MediaFlow."
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
        !mediaCopyQueue.isEmpty
            && mediaCopyQueue.allSatisfy { $0.repairIssues.isEmpty }
            && !isMediaCopyBusy
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

    var mediaCopyQueueRepairCount: Int {
        mediaCopyQueue.filter { !$0.repairIssues.isEmpty }.count
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

    init(
        folderSyncStorageRoot: URL? = nil,
        folderSyncTrashBoundary: FolderSyncTrashBoundary? = nil
    ) {
        do {
            let storageRoot: URL
            if let folderSyncStorageRoot {
                storageRoot = folderSyncStorageRoot
            } else {
                storageRoot = try FolderSyncServices.liveStorageRoot()
            }
            folderSyncServices = try FolderSyncServices(
                storageRoot: storageRoot,
                trashBoundary: folderSyncTrashBoundary
            )
            folderSyncServicesError = nil
        } catch {
            folderSyncServices = nil
            folderSyncServicesError = error.localizedDescription
        }

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

        if let folderSyncServices {
            syncHistory = folderSyncServices.historyStore.runs
            Task { [weak self, folderSyncServices] in
                let records = await folderSyncServices.mutationService.recoveryRecords()
                guard let self else { return }
                self.syncRecoveryRecords = records
            }
            if let loadFailure = folderSyncServices.historyStore.lastLoadFailure {
                statusMessage =
                    "Folder Sync history needs repair before Sync can run: \(loadFailure.problem)"
            }
        } else if let folderSyncServicesError {
            statusMessage =
                "Folder Sync recovery is unavailable, so Sync is disabled: \(folderSyncServicesError)"
        }
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
                    "Notifications enabled. Completion alerts appear when GPhil MediaFlow is in the background."
            case .denied:
                AppNotifier.openNotificationSettings()
                self?.statusMessage =
                    "Notifications are denied. Opened macOS Notification settings so you can enable GPhil MediaFlow there."
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
            self?.statusMessage = "Cleared GPhil MediaFlow notifications."
        }
    }

    func openNotificationSettings() {
        AppNotifier.openNotificationSettings()
        statusMessage =
            "Opened macOS Notification settings. If GPhil MediaFlow is not selected automatically, choose it there and enable notifications."
        refreshNotificationPermission()
    }

    func notifyCompletionIfNeeded(title: String, body: String) {
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
            "GPhil MediaFlow will move \(count) recorded Trash item\(count == 1 ? "" : "s") back to their original folder when the Trash item still exists and the original path is free."
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
            "This only removes GPhil MediaFlow's saved restore list for \(count) trashed file\(count == 1 ? "" : "s"). It does not delete or restore any files."
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

    func buildBackupRestorePlan() {
        guard canBuildBackupRestorePlan,
            let deletedFolder = restoreDeletedFolder,
            let backupRoot = restoreBackupRoot,
            let restoreRoot = restoreDestinationRoot
        else {
            statusMessage = "Choose deleted, backup, and restore folders before building a plan."
            return
        }

        let options = RestorePlanOptions(
            deletedFolder: deletedFolder,
            backupRoot: backupRoot,
            restoreRoot: restoreRoot,
            matchMode: restoreMatchMode,
            hashMode: restoreHashMode,
            includeHidden: restoreIncludeHidden
        )
        restoreCoordinator.buildPlan(options: options)
    }

    func applyBackupRestorePlan() {
        guard canApplyBackupRestorePlan else { return }

        let count = restorePlanRestorableCount
        let alert = NSAlert()
        alert.messageText = "Restore matched files?"
        alert.informativeText =
            "GPhil MediaFlow will copy \(count) matched file\(count == 1 ? "" : "s") to the restore root using \(restoreCopySource.title.lowercased()). Existing restore paths are \(restoreOverwriteExisting ? "overwritten" : "skipped")."
        alert.alertStyle = restoreOverwriteExisting ? .warning : .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreCoordinator.apply(
            records: restorePlanRecords,
            copySource: restoreCopySource,
            overwrite: restoreOverwriteExisting
        )
    }

    func cancelBackupRestorePlan() {
        restoreCoordinator.cancelBuild()
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
        panel.nameFieldStringValue = RestoreUnresolvedExporter.defaultFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let request = RestoreUnresolvedExportRequest(
            items: items,
            isPartialSearchSnapshot: isRestorePlanning || restorePlanStoppedWithPartialResults,
            deletedFolderPath: restoreDeletedFolder?.path(percentEncoded: false),
            backupRootPath: restoreBackupRoot?.path(percentEncoded: false),
            restoreRootPath: restoreDestinationRoot?.path(percentEncoded: false),
            matchMode: restoreMatchMode.title,
            hashMode: restoreHashMode.title,
            progressPhase: restorePlanProgress?.title,
            progressDetail: restorePlanProgress?.detail,
            deletedCount: restorePlanDeletedCount,
            restoredCount: restorePlanAlreadyRestoredCount
        )

        restoreCoordinator.exportUnresolvedItems(request, to: url)
    }

    func copyRestoreUnresolvedItemsToRestoreRoot() {
        let items = restoreUnresolvedExportItems
        guard let restoreRoot = restoreDestinationRoot, !items.isEmpty else {
            statusMessage = "No unresolved files to copy."
            return
        }

        let destinationFolder = restoreRoot.appendingPathComponent(
            "GPhil MediaFlow Unresolved Files",
            isDirectory: true
        )

        let alert = NSAlert()
        alert.messageText = "Copy unresolved files to the restore root?"
        alert.informativeText =
            "GPhil MediaFlow will copy \(items.count) unresolved file\(items.count == 1 ? "" : "s") into \(destinationFolder.path(percentEncoded: false)). Original subfolders are still unknown, so this creates a holding folder and does not overwrite existing files."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreCoordinator.copyUnresolvedItems(items, to: destinationFolder)
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
            "GPhil MediaFlow will rename \(itemCount) file\(itemCount == 1 ? "" : "s") in place. Extensions are preserved."
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
                "GPhil MediaFlow will move \(count) renamed file\(count == 1 ? "" : "s") back to their previous name. Files are skipped if the renamed source is missing or the previous name is already taken."
        case .redo:
            alert.informativeText =
                "GPhil MediaFlow will reapply \(count) previously undone rename\(count == 1 ? "" : "s"). Files are skipped if the original source is missing or the renamed target is already taken."
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
            "GPhil MediaFlow will move \(itemCount) file\(itemCount == 1 ? "" : "s") matching \(scopeDescription) to the macOS Trash from \(sourceRootCount) selected source folder\(sourceRootCount == 1 ? "" : "s").\(untouchedDescription) Restore records will be saved so these files can be moved back when the Trash items are still available. Total size: \(totalSize.formattedFileSize)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptMediaCopyConflictResolution(
        for plans: [MediaCopyBatchPlan]
    ) -> MediaCopyConflictResolution? {
        if let mediaCopyConflictResolutionHandler {
            return mediaCopyConflictResolutionHandler(plans)
        }
        return MediaCopyAppKitBoundary.resolveConflicts(in: plans)
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
            statusMessage = "Encoding cancelled because GPhil MediaFlow does not have permission to write to the output folder."
            return false
        }

        securityScopes.startEncoding(grantedRoots)
        let stillDenied = outputDirectories.filter { !securityScopes.canWriteTemporaryFile(in: $0) }
        guard stillDenied.isEmpty else {
            securityScopes.stopEncoding()
            let names = stillDenied.prefix(3).map { $0.path(percentEncoded: false) }.joined(separator: "\n")
            statusMessage = "GPhil MediaFlow still cannot write to:\n\(names)"
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
            "GPhil MediaFlow needs permission to write encoded files to the selected output folder. Choose the source/output folder, or a parent folder that contains all planned outputs."
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
        return "GPhil MediaFlow Queue \(formatter.string(from: Date())).\(QueueFile.fileExtension)"
    }

    private func normalizedQueueFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(QueueFile.fileExtension) : url
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

    func directoryURLIfExists(atPath path: String) -> URL? {
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

        if let data = settingsPersistence.data(forKey: DefaultsKey.trashedSourceRecords) {
            switch VersionedBlob.decodeEnvelope(
                from: data, currentVersion: 1, allowLegacyBareArray: true
            ) as Result<[TrashedSourceRecord], DecodeProblem> {
            case .success(let records):
                trashedSourceRecords = records
            case .failure(.versionMismatch):
                // Leave the blob intact for a newer build to read.
                statusMessage =
                    "Could not read saved trash records — they were saved by a newer version of GPhil MediaFlow and were kept. Restore-from-Trash may be unavailable until you upgrade."
            case .failure(.corrupt):
                settingsPersistence.preserveCorruptBlob(data, name: "trashed-source-records")
                statusMessage =
                    "Could not read saved trash records — the data appears damaged and was preserved to a backup file. Contact support before relying on Trash restore."
            }
        }
        if let data = settingsPersistence.data(forKey: DefaultsKey.mediaRenameHistory) {
            switch settingsPersistence.decodeMediaRenameHistory(from: data) {
            case .success(let document?):
                mediaRenameUndoStack = Array(
                    document.undoStack.suffix(Self.mediaRenameHistoryLimit)
                )
                mediaRenameRedoStack = Array(
                    document.redoStack.suffix(Self.mediaRenameHistoryLimit)
                )
            case .success(nil):
                break
            case .failure(.versionMismatch):
                statusMessage =
                    "Could not read rename history — it was saved by a newer version of GPhil MediaFlow and was kept."
            case .failure(.corrupt):
                settingsPersistence.preserveCorruptBlob(data, name: "media-rename-history")
                statusMessage =
                    "Could not read rename history — the data appears damaged and was preserved to a backup file."
            }
        }
        loadMediaRenameSettings()
        loadEncodingPresets()
        loadPendingTrashSourceRecords()

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.ffmpegSourcePreference),
            let value = FFmpegSourcePreference(rawValue: rawValue),
            FFmpegSourcePreference.selectableCases.contains(value)
        {
            ffmpegSourcePreference = value
        } else if FFmpegLocator.bundledFFmpegURL() == nil,
            FFmpegLocator.systemFFmpegURL() != nil
        {
            ffmpegSourcePreference = .system
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.fileManagementMode),
            let value = FileManagementMode(rawValue: rawValue)
        {
            fileManagementMode = value
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.outputMode),
            let persistedOutputMode = OutputMode(rawValue: rawValue)
        {
            outputMode = persistedOutputMode
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.encodingWorkflow),
            let persistedWorkflow = EncodingWorkflow(rawValue: rawValue)
        {
            encodingWorkflow = persistedWorkflow
        }

        exportFolder = settingsPersistence.directoryURL(forKey: DefaultsKey.exportFolderPath)
        if outputMode == .exportFolder, exportFolder == nil {
            outputMode = .sourceFolders
        }

        restoreDeletedFolder = settingsPersistence.directoryURL(
            forKey: DefaultsKey.restoreDeletedFolderPath
        )
        restoreBackupRoot = settingsPersistence.directoryURL(forKey: DefaultsKey.restoreBackupRootPath)
        restoreDestinationRoot = settingsPersistence.directoryURL(
            forKey: DefaultsKey.restoreDestinationRootPath
        )
        if let paths = settingsPersistence.stringArray(forKey: DefaultsKey.mediaCopySourceRootPaths) {
            mediaCopySourceRoots = paths.compactMap { directoryURLIfExists(atPath: $0) }
        } else if let sourceRoot = settingsPersistence.directoryURL(
            forKey: DefaultsKey.mediaCopySourceRootPath
        ) {
            mediaCopySourceRoots = [sourceRoot]
        }
        mediaCopyDestinationRoot = settingsPersistence.directoryURL(
            forKey: DefaultsKey.mediaCopyDestinationRootPath
        )
        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.mediaCopyDestinationLayout),
            let layout = MediaCopyDestinationLayout(rawValue: rawValue)
        {
            mediaCopyDestinationLayout = layout
        }
        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.mediaCopyFilter),
            let value = MediaFileFilter(rawValue: rawValue)
        {
            mediaCopyFilter = value
        }
        mediaFileNameFilterQuery =
            settingsPersistence.string(forKey: DefaultsKey.mediaFileNameFilterQuery) ?? ""
        if let extensions = settingsPersistence.stringArray(forKey: DefaultsKey.mediaCopyAudioExtensions) {
            mediaCopyAudioExtensions = Set(extensions.map { $0.lowercased() })
                .intersection(MediaFileFilter.audio.fileExtensions)
        }
        if let extensions = settingsPersistence.stringArray(forKey: DefaultsKey.mediaCopyVideoExtensions) {
            mediaCopyVideoExtensions = Set(extensions.map { $0.lowercased() })
                .intersection(MediaFileFilter.video.fileExtensions)
        }

        if let value = settingsPersistence.bool(forKey: DefaultsKey.syncOverwriteExisting) {
            syncOverwriteExisting = value
        }
        let persistedSyncPairs = settingsPersistence.data(forKey: DefaultsKey.syncFolderPairs)
        let hasPersistedSyncPairs = persistedSyncPairs.flatMap {
            try? SyncFolderPairPersistence.decode($0)
        }.map { !$0.isEmpty } ?? false
        let syncSafetySettings = FolderSyncSafetyPolicy.resolve(
            persistedDeleteDestinationItems: settingsPersistence.bool(
                forKey: DefaultsKey.syncDeleteDestinationItems
            ),
            persistedAutoSyncEnabled: settingsPersistence.bool(
                forKey: DefaultsKey.syncAutoSyncEnabled
            ),
            hasPersistedPairs: hasPersistedSyncPairs,
            acknowledgedVersion: settingsPersistence.int(
                forKey: DefaultsKey.syncSafetyAcknowledgementVersion
            )
        )
        syncDeleteDestinationItems = syncSafetySettings.deleteDestinationItems
        syncAutoSyncEnabled = syncSafetySettings.autoSyncEnabled
        syncSafetyMigrationNeedsAcknowledgement = syncSafetySettings.needsAcknowledgement
        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.syncDestinationLayout),
            let value = SyncDestinationLayout(rawValue: rawValue)
        {
            syncDestinationLayout = value
        }
        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.syncFileFilter),
            let value = SyncFileFilter(rawValue: rawValue)
        {
            syncFileFilter = value
        }
        syncCustomFileExtensions =
            settingsPersistence.string(forKey: DefaultsKey.syncCustomFileExtensions) ?? ""
        if let value = settingsPersistence.bool(forKey: DefaultsKey.completionNotificationsEnabled) {
            completionNotificationsEnabled = value
        }
        loadSyncFolderPairs()

        if let selectedInputExtensions = settingsPersistence.stringArray(
            forKey: DefaultsKey.selectedInputExtensions
        )
        {
            setSelectedInputExtensions(Set(selectedInputExtensions))
        }
        if let selectedVideoInputExtensions = settingsPersistence.stringArray(
            forKey: DefaultsKey.selectedVideoInputExtensions
        ) {
            setSelectedVideoInputExtensions(Set(selectedVideoInputExtensions))
        }

        if let value = settingsPersistence.bool(forKey: DefaultsKey.preserveSubfolders) {
            preserveSubfolders = value
        }

        if let value = settingsPersistence.bool(forKey: DefaultsKey.overwriteExisting) {
            overwriteExisting = value
        }

        if let value = settingsPersistence.bool(forKey: DefaultsKey.confirmBeforeEncoding) {
            confirmBeforeEncoding = value
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.outputFormat),
            let persistedOutputFormat = AudioOutputFormat(rawValue: rawValue)
        {
            outputFormat = persistedOutputFormat
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.videoOutputContainer),
            let persistedVideoContainer = VideoOutputContainer(rawValue: rawValue)
        {
            videoOutputContainer = persistedVideoContainer
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.hevcPreset),
            let persistedHEVCPreset = HEVCVideoPreset(rawValue: rawValue)
        {
            hevcPreset = persistedHEVCPreset
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.customVideoBitrateKbps) {
            customVideoBitrateKbps = max(500, min(value, 100_000))
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.videoScaleMode),
            let persistedVideoScaleMode = VideoScaleMode(rawValue: rawValue)
        {
            videoScaleMode = persistedVideoScaleMode
        } else {
            videoScaleMode = hevcPreset.defaultScaleMode
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.videoAudioMode),
            let persistedVideoAudioMode = VideoAudioMode(rawValue: rawValue)
        {
            videoAudioMode = persistedVideoAudioMode
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.videoHardwareDecodeMode),
            let persistedVideoHardwareDecodeMode = VideoHardwareDecodeMode(rawValue: rawValue)
        {
            videoHardwareDecodeMode = persistedVideoHardwareDecodeMode
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.mp3Mode),
            let persistedMP3Mode = MP3EncodingMode(rawValue: rawValue)
        {
            mp3Mode = persistedMP3Mode
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.vbrQuality),
            MP3EncodingOptions.vbrQualities.contains(value)
        {
            vbrQuality = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.cbrBitrateKbps),
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            cbrBitrateKbps = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.abrBitrateKbps),
            MP3EncodingOptions.bitrateKbps.contains(value)
        {
            abrBitrateKbps = value
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.oggMode),
            let value = OggEncodingOptions.Mode(rawValue: rawValue)
        {
            oggMode = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.oggQuality),
            OggEncodingOptions.qualities.contains(value)
        {
            oggQuality = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.oggBitrateKbps),
            OggEncodingOptions.bitrateKbps.contains(value)
        {
            oggBitrateKbps = value
        }

        if let rawValue = settingsPersistence.string(forKey: DefaultsKey.opusRateMode),
            let value = OpusEncodingOptions.RateMode(rawValue: rawValue)
        {
            opusRateMode = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.opusBitrateKbps),
            OpusEncodingOptions.bitrateKbps.contains(value)
        {
            opusBitrateKbps = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.flacCompressionLevel),
            FLACEncodingOptions.compressionLevels.contains(value)
        {
            flacCompressionLevel = value
        }

        if let value = settingsPersistence.bool(forKey: DefaultsKey.splitOversizedMultichannel) {
            splitOversizedMultichannel = value
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.parallelJobs) {
            parallelJobs = max(1, min(value, processorLimit))
        }

        if let value = settingsPersistence.int(forKey: DefaultsKey.ffmpegThreads) {
            ffmpegThreads = max(0, min(value, processorLimit))
        }
    }

    func lastInputDirectoryURL() -> URL? {
        settingsPersistence.directoryURL(forKey: DefaultsKey.lastInputDirectoryPath)
    }

    func rememberInputDirectory(fromFiles urls: [URL]) {
        guard let url = urls.first else { return }
        rememberInputDirectory(url.deletingLastPathComponent())
    }

    func rememberInputDirectory(_ url: URL?) {
        guard let url else { return }
        settingsPersistence.persistDirectory(url, forKey: DefaultsKey.lastInputDirectoryPath)
    }

    private func persistOptionalDirectory(_ url: URL?, forKey key: String) {
        settingsPersistence.persistOptionalDirectory(url, forKey: key)
    }

    private func persistedUUID(forKey key: String) -> UUID? {
        settingsPersistence.uuid(forKey: key)
    }

    private func persistOptionalUUID(_ id: UUID?, forKey key: String) {
        settingsPersistence.persistOptionalUUID(id, forKey: key, isLoading: isLoadingPersistedSettings)
    }

    private func persistMediaCopySourceRoots() {
        settingsPersistence.persistMediaCopySourceRootPaths(mediaCopySourceRoots)
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
        settingsPersistence.set(extensions.sorted(), forKey: key)
    }

    func chooseDirectory(title: String, prompt: String, initialURL: URL?) -> URL? {
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

    func validateMediaCopyFolders(sourceRoot: URL, destinationRoot: URL) -> Bool {
        if let mediaCopyFolderValidationHandler {
            return mediaCopyFolderValidationHandler(sourceRoot, destinationRoot)
        }
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

    func showMediaCopyFolderAlert(message: String, detail: String) {
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
            settingsPersistence.removeObject(forKey: DefaultsKey.trashedSourceRecords)
            return
        }

        if let data = try? VersionedBlob.encode(trashedSourceRecords, currentVersion: 1) {
            settingsPersistence.set(data, forKey: DefaultsKey.trashedSourceRecords)
        }
    }

    private func persistMediaRenameHistory() {
        if mediaRenameUndoStack.isEmpty && mediaRenameRedoStack.isEmpty {
            settingsPersistence.removeObject(forKey: DefaultsKey.mediaRenameHistory)
            return
        }

        if let data = settingsPersistence.encodeMediaRenameHistory(
            undoStack: mediaRenameUndoStack,
            redoStack: mediaRenameRedoStack
        ) {
            settingsPersistence.set(data, forKey: DefaultsKey.mediaRenameHistory)
        }
    }

    private func persistMediaRenameSettings() {
        let settings = currentMediaRenameSettings()
        if let data = settingsPersistence.encodeMediaRenameSettings(settings) {
            settingsPersistence.set(data, forKey: DefaultsKey.mediaRenameSettings)
        }
    }

    private func persistEncodingPresets() {
        let document = EncodingPresetDocument(presets: encodingPresets)
        if let data = try? JSONEncoder().encode(document) {
            settingsPersistence.set(data, forKey: DefaultsKey.encodingPresets)
        }
    }

    private func loadEncodingPresets() {
        if let data = settingsPersistence.data(forKey: DefaultsKey.encodingPresets) {
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
        settingsPersistence.forcePersistOptionalUUID(
            normalized.audioID,
            forKey: DefaultsKey.selectedAudioEncodingPresetID
        )
        settingsPersistence.forcePersistOptionalUUID(
            normalized.videoID,
            forKey: DefaultsKey.selectedVideoEncodingPresetID
        )
    }

    private func loadMediaRenameSettings() {
        guard let data = settingsPersistence.data(forKey: DefaultsKey.mediaRenameSettings) else {
            return
        }

        switch settingsPersistence.decodeMediaRenameSettings(from: data) {
        case .success(let settings?):
            applyMediaRenameSettings(settings)
        case .success(nil):
            break
        case .failure(.versionMismatch):
            statusMessage =
                "Could not read rename settings — they were saved by a newer version of GPhil MediaFlow and were kept."
        case .failure(.corrupt):
            settingsPersistence.preserveCorruptBlob(data, name: "media-rename-settings")
            statusMessage =
                "Could not read rename settings — the data appears damaged and was preserved to a backup file."
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
                "Could not read the trash emergency journal — it was saved by a newer version of GPhil MediaFlow and was kept."
        case .failure(.corrupt):
            settingsPersistence.preserveCorruptBlob(data, name: "trash-emergency-journal")
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

    static func normalizedExtensionSet(from text: String) -> Set<String> {
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
