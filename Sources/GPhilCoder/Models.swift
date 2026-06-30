import Foundation
import GPhilCoderCore

enum FileManagementMode: String, CaseIterable, Identifiable, Sendable {
    case copy
    case delete
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy:
            "Copy"
        case .delete:
            "Delete"
        case .rename:
            "Rename"
        }
    }

    var symbolName: String {
        switch self {
        case .copy:
            "doc.on.doc"
        case .delete:
            "trash"
        case .rename:
            "pencil"
        }
    }
}

enum AudioFormat {
    static let inputExtensions: Set<String> = Set(InputAudioFormat.allCases.flatMap(\.fileExtensions))
    static let readableInputList = readableList(for: inputExtensions)

    static func readableList(for extensions: Set<String>) -> String {
        guard !extensions.isEmpty else { return "None" }
        return extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }
}

enum VideoFormat {
    static let inputExtensions: Set<String> = Set(InputVideoFormat.allCases.flatMap(\.fileExtensions))
    static let readableInputList = AudioFormat.readableList(for: inputExtensions)
}

enum FFmpegSourcePreference: String, CaseIterable, Identifiable {
    case bundled
    case system

    static var selectableCases: [FFmpegSourcePreference] {
        #if APP_STORE
        [.bundled]
        #else
        allCases
        #endif
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled:
            "Bundled"
        case .system:
            "System"
        }
    }

    var detail: String {
        switch self {
        case .bundled:
            "Use the FFmpeg shipped inside GPhilCoder."
        case .system:
            "Use FFmpeg discovered on this Mac."
        }
    }
}

enum InputAudioFormat: String, CaseIterable, Identifiable {
    case flac
    case wav
    case mp3
    case m4a
    case aac
    case aiff
    case ogg
    case opus
    case wavpack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flac:
            "FLAC"
        case .wav:
            "WAV"
        case .mp3:
            "MP3"
        case .m4a:
            "M4A"
        case .aac:
            "AAC"
        case .aiff:
            "AIFF"
        case .ogg:
            "Ogg"
        case .opus:
            "Opus"
        case .wavpack:
            "WavPack"
        }
    }

    var fileExtensions: Set<String> {
        switch self {
        case .flac:
            ["flac"]
        case .wav:
            ["wav"]
        case .mp3:
            ["mp3"]
        case .m4a:
            ["m4a"]
        case .aac:
            ["aac"]
        case .aiff:
            ["aif", "aiff"]
        case .ogg:
            ["ogg"]
        case .opus:
            ["opus"]
        case .wavpack:
            ["wv"]
        }
    }
}

enum InputVideoFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov
    case m4v

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4:
            "MP4"
        case .mov:
            "MOV"
        case .m4v:
            "M4V"
        }
    }

    var fileExtensions: Set<String> {
        switch self {
        case .mp4:
            ["mp4"]
        case .mov:
            ["mov"]
        case .m4v:
            ["m4v"]
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case sourceFolders
    case exportFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sourceFolders:
            "Source folders"
        case .exportFolder:
            "Export folder"
        }
    }
}

enum MultichannelSplitOptions {
    static let wavPackGroupSize = 10
}

enum JobState: Equatable {
    case queued
    case running
    case succeeded
    case skipped
    case failed
    case cancelled

    var label: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Encoding"
        case .succeeded:
            "Done"
        case .skipped:
            "Skipped"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var filterTitle: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .succeeded:
            "Success"
        case .skipped:
            "Skipped"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .queued:
            "clock"
        case .running:
            "waveform"
        case .succeeded:
            "checkmark.circle.fill"
        case .skipped:
            "forward.end.circle"
        case .failed:
            "xmark.octagon.fill"
        case .cancelled:
            "stop.circle"
        }
    }
}

struct AudioInputItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let sourceRoot: URL?
    let relativeDirectory: String?
    let fileSizeBytes: Int64

    var name: String {
        url.lastPathComponent
    }

    var displayDirectory: String {
        url.deletingLastPathComponent().path(percentEncoded: false)
    }

    var encodingWorkflow: EncodingWorkflow? {
        let fileExtension = url.pathExtension.lowercased()
        if AudioFormat.inputExtensions.contains(fileExtension) {
            return .audio
        }
        if VideoFormat.inputExtensions.contains(fileExtension) {
            return .video
        }
        return nil
    }

    func outputFileName(for format: AudioOutputFormat) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let outputBaseName = url.pathExtension.lowercased() == format.fileExtension
            ? "\(baseName)-encoded"
            : baseName
        return outputBaseName + "." + format.fileExtension
    }

    func outputFileName(for container: VideoOutputContainer) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let outputBaseName = url.pathExtension.lowercased() == container.fileExtension
            ? "\(baseName)-encoded"
            : baseName
        return outputBaseName + "." + container.fileExtension
    }
}

struct EncodeJob: Identifiable {
    let id = UUID()
    let item: AudioInputItem
    let outputURL: URL
    var state: JobState = .queued
    var message: String = ""
    var diagnosticMessage: String = ""
    var startedAt: Date?
    var finishedAt: Date?

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

struct QueueDocument: Codable {
    static let currentVersion = 1

    let version: Int
    let savedAt: Date
    let settings: QueueSettings
    let items: [QueueInput]
}

struct QueueSettings: Codable {
    var encodingWorkflow: String?
    var outputMode: String?
    var exportFolderPath: String?
    var selectedInputExtensions: [String]?
    var selectedVideoInputExtensions: [String]?
    var preserveSubfolders: Bool?
    var overwriteExisting: Bool?
    var outputFormat: String?
    var videoOutputContainer: String?
    var hevcPreset: String?
    var customVideoBitrateKbps: Int?
    var videoScaleMode: String?
    var videoAudioMode: String?
    var videoHardwareDecodeMode: String?
    var mp3Mode: String?
    var vbrQuality: Int?
    var cbrBitrateKbps: Int?
    var abrBitrateKbps: Int?
    var oggMode: String?
    var oggQuality: Int?
    var oggBitrateKbps: Int?
    var opusRateMode: String?
    var opusBitrateKbps: Int?
    var flacCompressionLevel: Int?
    var splitOversizedMultichannel: Bool?
    var parallelJobs: Int?
    var ffmpegThreads: Int?
}

struct QueueInput: Codable {
    let urlPath: String
    let sourceRootPath: String?
    let relativeDirectory: String?
}

struct TrashedSourceRecord: Codable, Identifiable {
    let id: UUID
    let name: String
    let originalPath: String
    let trashPath: String
    let sourceRootPath: String?
    let relativeDirectory: String?
    let fileSizeBytes: Int64
    let trashedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        originalPath: String,
        trashPath: String,
        sourceRootPath: String?,
        relativeDirectory: String?,
        fileSizeBytes: Int64,
        trashedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.sourceRootPath = sourceRootPath
        self.relativeDirectory = relativeDirectory
        self.fileSizeBytes = fileSizeBytes
        self.trashedAt = trashedAt
    }
}

struct PendingTrashSourceRecord: Codable, Identifiable {
    let id: UUID
    let name: String
    let originalPath: String
    let sourceRootPath: String?
    let relativeDirectory: String?
    let fileSizeBytes: Int64
    let requestedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        originalPath: String,
        sourceRootPath: String?,
        relativeDirectory: String?,
        fileSizeBytes: Int64,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.sourceRootPath = sourceRootPath
        self.relativeDirectory = relativeDirectory
        self.fileSizeBytes = fileSizeBytes
        self.requestedAt = requestedAt
    }
}

struct AddSummary {
    var added = 0
    var duplicates = 0
    var unsupported = 0

    var message: String {
        var parts: [String] = []
        if added > 0 {
            parts.append("Added \(added) \(added == 1 ? "file" : "files")")
        }
        if duplicates > 0 {
            parts.append("ignored \(duplicates) duplicate\(duplicates == 1 ? "" : "s")")
        }
        if unsupported > 0 {
            parts.append("skipped \(unsupported) unsupported item\(unsupported == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No compatible audio files found." : parts.joined(separator: ", ") + "."
    }
}

enum SyncPairState: String, Codable, Sendable {
    case idle
    case watching
    case syncing
    case succeeded
    case failed
    case disabled

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .watching:
            "Watching"
        case .syncing:
            "Syncing"
        case .succeeded:
            "Synced"
        case .failed:
            "Needs attention"
        case .disabled:
            "Paused"
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            "clock"
        case .watching:
            "eye"
        case .syncing:
            "arrow.triangle.2.circlepath"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .disabled:
            "pause.circle"
        }
    }
}

enum SyncDestinationLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case originSubfolder
    case destinationRoot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .originSubfolder:
            "Origin folder"
        case .destinationRoot:
            "Root"
        }
    }

    var detail: String {
        switch self {
        case .originSubfolder:
            "Each origin syncs into its own folder inside the selected destination."
        case .destinationRoot:
            "Each origin mirrors directly into the selected destination folder."
        }
    }
}

struct SyncFolderPair: Codable, Identifiable, Equatable {
    let id: UUID
    var originPath: String
    var destinationPath: String
    var isEnabled: Bool
    var addedAt: Date
    var lastSyncedAt: Date?
    var lastMessage: String
    var state: SyncPairState

    init(
        id: UUID = UUID(),
        originPath: String,
        destinationPath: String,
        isEnabled: Bool = true,
        addedAt: Date = Date(),
        lastSyncedAt: Date? = nil,
        lastMessage: String = "Ready to sync.",
        state: SyncPairState = .idle
    ) {
        self.id = id
        self.originPath = originPath
        self.destinationPath = destinationPath
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.lastSyncedAt = lastSyncedAt
        self.lastMessage = lastMessage
        self.state = state
    }

    var originURL: URL {
        URL(fileURLWithPath: originPath, isDirectory: true)
    }

    var destinationURL: URL {
        URL(fileURLWithPath: destinationPath, isDirectory: true)
    }

    func effectiveDestinationURL(layout: SyncDestinationLayout) -> URL {
        switch layout {
        case .destinationRoot:
            destinationURL
        case .originSubfolder:
            destinationURL.appendingPathComponent(originURL.lastPathComponent, isDirectory: true)
        }
    }

    var displayTitle: String {
        "\(originURL.lastPathComponent) -> \(destinationURL.lastPathComponent)"
    }
}

struct FolderSyncProgress: Equatable {
    let completed: Int
    let total: Int
    let copied: Int
    let deleted: Int
    let skipped: Int
    let failed: Int
    let copiedBytes: Int64
    let totalBytes: Int64
    let startedAt: Date
    let updatedAt: Date
    let currentPath: String?

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var bytesPerSecond: Double? {
        let elapsed = updatedAt.timeIntervalSince(startedAt)
        guard elapsed > 0, copiedBytes > 0 else { return nil }
        return Double(copiedBytes) / elapsed
    }
}

struct FolderSyncRunResult: Sendable {
    var pairs = 0
    var operations = 0
    var copied = 0
    var deleted = 0
    var skipped = 0
    var failed = 0
    var failedPaths: [String] = []
    var cancelled = false
}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    var formattedMegabytesPerSecond: String {
        let megabytesPerSecond = self / 1_000_000
        if megabytesPerSecond > 0, megabytesPerSecond < 0.1 {
            return "< 0.1 MB/s"
        }
        return String(format: "%.1f MB/s", megabytesPerSecond)
    }
}
