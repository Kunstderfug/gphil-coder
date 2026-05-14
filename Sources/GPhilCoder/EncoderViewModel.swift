import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EncoderViewModel: ObservableObject {
    private enum DefaultsKey {
        static let lastInputDirectoryPath = "lastInputDirectoryPath"
        static let outputMode = "outputMode"
        static let exportFolderPath = "exportFolderPath"
        static let selectedInputExtensions = "selectedInputExtensions"
        static let preserveSubfolders = "preserveSubfolders"
        static let overwriteExisting = "overwriteExisting"
        static let outputFormat = "outputFormat"
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
        static let parallelJobs = "parallelJobs"
        static let ffmpegThreads = "ffmpegThreads"
        static let ffmpegSourcePreference = "ffmpegSourcePreference"
        static let trashedSourceRecords = "trashedSourceRecords"
    }

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

    @Published private(set) var inputs: [AudioInputItem] = []
    @Published private(set) var jobs: [EncodeJob] = []
    @Published private(set) var isEncoding = false
    @Published private(set) var ffmpegURL: URL?
    @Published private(set) var bundledFFmpegURL: URL?
    @Published private(set) var systemFFmpegURL: URL?
    @Published private(set) var ffmpegCapabilities = FFmpegCapabilities()
    @Published private(set) var statusMessage = "Add audio files or folders to begin."
    @Published private(set) var trashedSourceRecords: [TrashedSourceRecord] = [] {
        didSet { persistTrashedSourceRecords() }
    }

    @Published private(set) var selectedInputExtensions: Set<String> = AudioFormat.inputExtensions {
        didSet {
            UserDefaults.standard.set(
                selectedInputExtensions.sorted(),
                forKey: DefaultsKey.selectedInputExtensions
            )
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

    var processorLimit: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    var canEncode: Bool {
        !activeInputs.isEmpty && !isEncoding && ffmpegURL != nil
            && (outputMode == .sourceFolders || exportFolder != nil)
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

    var totalInputSize: Int64 {
        inputs.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var activeInputs: [AudioInputItem] {
        inputs.filter { isSelectedInputAudio($0.url) }
    }

    var inactiveInputCount: Int {
        inputs.count - activeInputs.count
    }

    var activeInputSize: Int64 {
        activeInputs.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var sameFormatInputCount: Int {
        activeInputs.filter { $0.url.pathExtension.lowercased() == outputFormat.fileExtension }
            .count
    }

    var sameFormatWarningMessage: String? {
        guard sameFormatInputCount > 0 else { return nil }
        let noun = sameFormatInputCount == 1 ? "source already uses" : "sources already use"
        return
            "\(sameFormatInputCount) \(noun) .\(outputFormat.fileExtension). Same-format exports are written with \"-encoded\" before the extension, and exact source overwrites are blocked."
    }

    var lossyToLosslessWarningMessage: String? {
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

    var selectedEncoderName: String {
        switch outputFormat {
        case .ogg:
            supportsOggBitrate ? "libvorbis" : "vorbis"
        default:
            outputFormat.codecName
        }
    }

    var selectedInputReadableList: String {
        if selectedInputExtensions == AudioFormat.inputExtensions {
            return "All formats"
        }

        let selectedFormats = InputAudioFormat.allCases
            .filter { !$0.fileExtensions.isDisjoint(with: selectedInputExtensions) }
            .map(\.title)

        return selectedFormats.isEmpty ? "None" : selectedFormats.joined(separator: ", ")
    }

    var hasSelectedInputFilters: Bool {
        !selectedInputExtensions.isEmpty
    }

    var canRestoreTrashedSources: Bool {
        !isEncoding && !trashedSourceRecords.isEmpty
    }

    var activeFilterStatusMessage: String {
        if inputs.isEmpty {
            return "Input filter set to \(selectedInputReadableList)."
        }

        let activeCount = activeInputs.count
        let hiddenCount = inactiveInputCount
        if hiddenCount == 0 {
            return "Input filter set to \(selectedInputReadableList). \(activeCount) queued file\(activeCount == 1 ? "" : "s") active."
        }

        return "Input filter set to \(selectedInputReadableList). \(activeCount) active, \(hiddenCount) hidden until their formats are re-enabled."
    }

    var ffmpegSourceTitle: String {
        ffmpegSourcePreference.title
    }

    var activeFFmpegPath: String {
        ffmpegURL?.path(percentEncoded: false) ?? "No executable selected"
    }

    init() {
        loadPersistedSettings()
        refreshFFmpeg()
    }

    func refreshFFmpeg() {
        bundledFFmpegURL = FFmpegLocator.bundledFFmpegURL()
        systemFFmpegURL = FFmpegLocator.systemFFmpegURL()
        ffmpegURL = FFmpegLocator.locate(preference: ffmpegSourcePreference)

        if let ffmpegURL {
            ffmpegCapabilities = FFmpegCapabilities.detect(ffmpegURL: ffmpegURL)
            let vorbisStatus =
                ffmpegCapabilities.hasLibVorbis ? "libvorbis available" : "native Vorbis only"
            let source = FFmpegLocator.isBundled(ffmpegURL) ? "bundled FFmpeg" : "system FFmpeg"
            statusMessage =
                "Using \(source) at \(ffmpegURL.path(percentEncoded: false)) (\(vorbisStatus))."
        } else {
            ffmpegCapabilities = FFmpegCapabilities()
            switch ffmpegSourcePreference {
            case .bundled:
                statusMessage =
                    "Bundled FFmpeg was not found in this app. Select System FFmpeg or rebuild the app with BUNDLED_FFMPEG."
            case .system:
                statusMessage = FFmpegToolError.notFound.localizedDescription
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

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Audio Files"
        panel.prompt = "Add Files"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = AudioFormat.inputExtensions.compactMap {
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

    func setInputFormat(_ format: InputAudioFormat, enabled: Bool) {
        guard !isEncoding else { return }
        if enabled {
            selectedInputExtensions.formUnion(format.fileExtensions)
        } else {
            selectedInputExtensions.subtract(format.fileExtensions)
        }
        jobs.removeAll()
        statusMessage = activeFilterStatusMessage
    }

    func isInputFormatEnabled(_ format: InputAudioFormat) -> Bool {
        format.fileExtensions.isSubset(of: selectedInputExtensions)
    }

    func selectAllInputFormats() {
        guard !isEncoding else { return }
        selectedInputExtensions = AudioFormat.inputExtensions
        jobs.removeAll()
        statusMessage = activeFilterStatusMessage
    }

    func deselectAllInputFormats() {
        guard !isEncoding else { return }
        selectedInputExtensions.removeAll()
        jobs.removeAll()
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

        do {
            try moveItemToTrashAndRecord(item)
            inputs.removeAll { $0.id == item.id }
            jobs.removeAll()
            statusMessage = "Moved \(item.name) to Trash."
        } catch {
            statusMessage = "Could not move \(item.name) to Trash: \(error.localizedDescription)"
        }
    }

    func trashAllInputSources() {
        let itemsToTrash = activeInputs
        guard !isEncoding, !itemsToTrash.isEmpty else { return }

        let count = itemsToTrash.count
        let hiddenCount = inactiveInputCount
        let alert = NSAlert()
        alert.messageText = "Move active source files to Trash?"
        var details =
            "This will move \(count) active source file\(count == 1 ? "" : "s") to the macOS Trash and remove successful items from the queue."
        if hiddenCount > 0 {
            details +=
                " \(hiddenCount) hidden queued file\(hiddenCount == 1 ? "" : "s") will stay untouched."
        }
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move Active to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashedIDs = Set<UUID>()
        var failures: [String] = []

        for item in itemsToTrash {
            do {
                try moveItemToTrashAndRecord(item)
                trashedIDs.insert(item.id)
            } catch {
                failures.append(item.name)
            }
        }

        inputs.removeAll { trashedIDs.contains($0.id) }
        jobs.removeAll()

        if failures.isEmpty {
            statusMessage =
                "Moved \(trashedIDs.count) active source file\(trashedIDs.count == 1 ? "" : "s") to Trash."
        } else {
            statusMessage =
                "Moved \(trashedIDs.count) active source file\(trashedIDs.count == 1 ? "" : "s") to Trash. Could not move \(failures.count): \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? "..." : "")."
        }
    }

    func restoreTrashedSources() {
        guard canRestoreTrashedSources else { return }

        let count = trashedSourceRecords.count
        let alert = NSAlert()
        alert.messageText = "Restore trashed source files?"
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

        let restoredIDs = Set(restored.map(\.id))
        trashedSourceRecords.removeAll { restoredIDs.contains($0.id) }
        jobs.removeAll()

        var details = [
            "Restored \(restored.count) source file\(restored.count == 1 ? "" : "s")."
        ]
        if !unavailable.isEmpty {
            details.append(
                "\(unavailable.count) Trash item\(unavailable.count == 1 ? "" : "s") no longer found."
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

    func clearInputs() {
        guard !isEncoding else { return }
        inputs.removeAll()
        jobs.removeAll()
        statusMessage = "Queue cleared."
    }

    func saveQueue() {
        guard !isEncoding else { return }
        guard !inputs.isEmpty else {
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
            items: inputs.map { queueInput(from: $0) }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved queue with \(inputs.count) item\(inputs.count == 1 ? "" : "s") to \(url.lastPathComponent)."
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
        NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
    }

    func startEncoding() {
        guard canEncode, let ffmpegURL else { return }

        if outputFormat == .ogg, oggMode == .bitrate, !supportsOggBitrate {
            statusMessage = FFmpegToolError.unsupportedOggBitrate.localizedDescription
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
        jobs = plannedJobs
        isEncoding = true

        let settings = EncodingSettingsSnapshot(
            ffmpegURL: ffmpegURL,
            useLibVorbis: ffmpegCapabilities.hasLibVorbis,
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
            ffmpegThreads: ffmpegThreads,
            overwriteExisting: overwriteExisting,
            parallelJobs: max(1, min(parallelJobs, processorLimit))
        )

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

    private func defaultQueueFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhilCoder Queue \(formatter.string(from: Date())).\(QueueFile.fileExtension)"
    }

    private func normalizedQueueFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(QueueFile.fileExtension) : url
    }

    private func currentQueueSettings() -> QueueSettings {
        QueueSettings(
            outputMode: outputMode.rawValue,
            exportFolderPath: exportFolder?.standardizedFileURL.path(percentEncoded: false),
            selectedInputExtensions: selectedInputExtensions.sorted(),
            preserveSubfolders: preserveSubfolders,
            overwriteExisting: overwriteExisting,
            outputFormat: outputFormat.rawValue,
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
            parallelJobs: max(1, min(parallelJobs, processorLimit)),
            ffmpegThreads: max(0, min(ffmpegThreads, processorLimit))
        )
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

        if let selectedInputExtensions = settings.selectedInputExtensions {
            setSelectedInputExtensions(Set(selectedInputExtensions))
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

            guard isSupportedAudio(url) else {
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
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: DefaultsKey.trashedSourceRecords),
            let records = try? JSONDecoder().decode([TrashedSourceRecord].self, from: data)
        {
            trashedSourceRecords = records
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.ffmpegSourcePreference),
            let value = FFmpegSourcePreference(rawValue: rawValue)
        {
            ffmpegSourcePreference = value
        } else if FFmpegLocator.bundledFFmpegURL() == nil,
            FFmpegLocator.systemFFmpegURL() != nil
        {
            ffmpegSourcePreference = .system
        }

        if let rawValue = defaults.string(forKey: DefaultsKey.outputMode),
            let persistedOutputMode = OutputMode(rawValue: rawValue)
        {
            outputMode = persistedOutputMode
        }

        exportFolder = persistedDirectoryURL(forKey: DefaultsKey.exportFolderPath)
        if outputMode == .exportFolder, exportFolder == nil {
            outputMode = .sourceFolders
        }

        if let selectedInputExtensions = defaults.array(forKey: DefaultsKey.selectedInputExtensions)
            as? [String]
        {
            setSelectedInputExtensions(Set(selectedInputExtensions))
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

    private func persistTrashedSourceRecords() {
        if trashedSourceRecords.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.trashedSourceRecords)
            return
        }

        if let data = try? JSONEncoder().encode(trashedSourceRecords) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.trashedSourceRecords)
        }
    }

    private func setSelectedInputExtensions(_ extensions: Set<String>) {
        let supported = extensions.intersection(AudioFormat.inputExtensions)
        selectedInputExtensions = supported
        jobs.removeAll()
    }

    private func moveItemToTrashAndRecord(_ item: AudioInputItem) throws {
        let originalPath = item.url.standardizedFileURL.path(percentEncoded: false)
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingItemURL)

        guard let trashURL = resultingItemURL as URL? else { return }

        let record = TrashedSourceRecord(
            name: item.name,
            originalPath: originalPath,
            trashPath: trashURL.standardizedFileURL.path(percentEncoded: false),
            sourceRootPath: item.sourceRoot?.standardizedFileURL.path(percentEncoded: false),
            relativeDirectory: item.relativeDirectory,
            fileSizeBytes: item.fileSizeBytes
        )
        trashedSourceRecords.insert(record, at: 0)
    }

    private func appendRestoredInput(from record: TrashedSourceRecord, restoredURL: URL) {
        guard isSupportedAudio(restoredURL) else { return }

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
            guard isSupportedAudio(url) else {
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

            guard isSupportedAudio(url) else {
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

    private func isSelectedInputAudio(_ url: URL) -> Bool {
        selectedInputExtensions.contains(url.pathExtension.lowercased())
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

        return outputDirectory.appendingPathComponent(item.outputFileName(for: outputFormat))
    }

    private func runJobs(settings: EncodingSettingsSnapshot) async {
        await withTaskGroup(of: JobResult.self) { group in
            var nextIndex = 0
            let initialCount = min(settings.parallelJobs, jobs.count)

            while nextIndex < initialCount {
                let job = markJobRunning(at: nextIndex)
                group.addTask {
                    await Self.encode(job: job, settings: settings)
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
                    group.addTask {
                        await Self.encode(job: job, settings: settings)
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

        if failedCount > 0 {
            statusMessage = "Finished with \(failedCount) failure\(failedCount == 1 ? "" : "s")."
        } else if skippedCount > 0 {
            statusMessage = "Finished. \(skippedCount) file\(skippedCount == 1 ? "" : "s") skipped."
        } else if completedCount > 0 {
            statusMessage =
                "Finished \(completedCount) \(settings.outputFormat.title) export\(completedCount == 1 ? "" : "s")."
        } else {
            statusMessage = "No files were encoded."
        }
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
        let encoder = FFmpegEncoder(ffmpegURL: settings.ffmpegURL)

        do {
            let output = try await encoder.encode(
                input: job.item.url, output: job.outputURL, settings: settings)
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
