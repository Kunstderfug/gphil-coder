import Foundation
import GPhilCoderCore

struct SettingsPersistence {
    enum Key {
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
        static let syncSafetyAcknowledgementVersion = "syncSafetyAcknowledgementVersion"
        static let completionNotificationsEnabled = "completionNotificationsEnabled"
    }

    struct MediaRenameHistoryDocument: Codable, Sendable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var undoStack: [MediaRenameHistoryTransaction]
        var redoStack: [MediaRenameHistoryTransaction]
    }

    struct MediaRenameSettingsDocument: Codable, Sendable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var settings: MediaRenameSettings
    }

    private static let applicationSupportDirectoryName = "GPhilCoder"

    var defaults: UserDefaults = .standard

    func bool(forKey key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    func int(forKey key: String) -> Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func stringArray(forKey key: String) -> [String]? {
        defaults.array(forKey: key) as? [String]
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Data, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    func directoryURL(forKey key: String) -> URL? {
        guard let path = defaults.string(forKey: key) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func persistDirectory(_ url: URL, forKey key: String) {
        defaults.set(url.standardizedFileURL.path(percentEncoded: false), forKey: key)
    }

    func persistOptionalDirectory(_ url: URL?, forKey key: String) {
        guard let url else {
            defaults.removeObject(forKey: key)
            return
        }
        persistDirectory(url, forKey: key)
    }

    func uuid(forKey key: String) -> UUID? {
        guard let value = defaults.string(forKey: key) else { return nil }
        return UUID(uuidString: value)
    }

    func persistOptionalUUID(_ id: UUID?, forKey key: String, isLoading: Bool) {
        guard !isLoading else { return }
        forcePersistOptionalUUID(id, forKey: key)
    }

    func forcePersistOptionalUUID(_ id: UUID?, forKey key: String) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func persistMediaCopySourceRootPaths(_ urls: [URL]) {
        let paths = urls.map {
            $0.standardizedFileURL.path(percentEncoded: false)
        }

        if paths.isEmpty {
            defaults.removeObject(forKey: Key.mediaCopySourceRootPaths)
            defaults.removeObject(forKey: Key.mediaCopySourceRootPath)
        } else {
            defaults.set(paths, forKey: Key.mediaCopySourceRootPaths)
            defaults.set(paths[0], forKey: Key.mediaCopySourceRootPath)
        }
    }

    func encodeMediaRenameHistory(
        undoStack: [MediaRenameHistoryTransaction],
        redoStack: [MediaRenameHistoryTransaction]
    ) -> Data? {
        let document = MediaRenameHistoryDocument(
            undoStack: undoStack,
            redoStack: redoStack
        )
        return try? JSONEncoder().encode(document)
    }

    func decodeMediaRenameHistory(
        from data: Data
    ) -> Result<MediaRenameHistoryDocument?, DecodeProblem> {
        let result = VersionedBlob.decode(
            from: data,
            currentVersion: MediaRenameHistoryDocument.currentVersion,
            decodePayload: { data in
                let document = try JSONDecoder().decode(
                    MediaRenameHistoryDocument.self, from: data
                )
                guard document.version == MediaRenameHistoryDocument.currentVersion else {
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
            return .success(documents.first)
        case .failure(let problem):
            return .failure(problem)
        }
    }

    func encodeMediaRenameSettings(_ settings: MediaRenameSettings) -> Data? {
        try? JSONEncoder().encode(MediaRenameSettingsDocument(settings: settings))
    }

    func decodeMediaRenameSettings(from data: Data) -> Result<MediaRenameSettings?, DecodeProblem> {
        let result = VersionedBlob.decode(
            from: data,
            currentVersion: MediaRenameSettingsDocument.currentVersion,
            decodePayload: { data in
                [try JSONDecoder().decode(MediaRenameSettingsDocument.self, from: data).settings]
            },
            legacyBareArray: { data in
                guard let settings = try? JSONDecoder().decode(
                    MediaRenameSettings.self, from: data
                ) else { return nil }
                return [settings]
            }
        ) as Result<[MediaRenameSettings], DecodeProblem>

        switch result {
        case .success(let settings):
            return .success(settings.first)
        case .failure(let problem):
            return .failure(problem)
        }
    }

    func preserveCorruptBlob(_ data: Data, name: String) {
        do {
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = baseURL.appendingPathComponent(
                Self.applicationSupportDirectoryName,
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
            // Best-effort: callers surface the decode problem in status text.
        }
    }
}
