import Foundation

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

enum EncodingWorkflow: String, CaseIterable, Codable, Identifiable {
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio:
            "Audio"
        case .video:
            "Video"
        }
    }

    var queueNoun: String {
        switch self {
        case .audio:
            "audio file"
        case .video:
            "video file"
        }
    }

    var symbolName: String {
        switch self {
        case .audio:
            "waveform"
        case .video:
            "film"
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

enum AudioOutputFormat: String, CaseIterable, Codable, Identifiable {
    case mp3
    case ogg
    case opus
    case flac
    case wavpack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp3:
            "MP3"
        case .ogg:
            "Ogg"
        case .opus:
            "Opus"
        case .flac:
            "FLAC"
        case .wavpack:
            "WavPack"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3:
            "mp3"
        case .ogg:
            "ogg"
        case .opus:
            "opus"
        case .flac:
            "flac"
        case .wavpack:
            "wv"
        }
    }

    var detail: String {
        switch self {
        case .mp3:
            "Broad compatibility with VBR, CBR, and ABR modes."
        case .ogg:
            "Ogg Vorbis output with quality-based compression."
        case .opus:
            "Modern Opus output, efficient for music and speech."
        case .flac:
            "Lossless FLAC output with selectable compression level."
        case .wavpack:
            "Lossless WavPack output, excellent for high-bit-depth audio archives."
        }
    }

    var codecName: String {
        switch self {
        case .mp3:
            "libmp3lame"
        case .ogg:
            "vorbis"
        case .opus:
            "libopus"
        case .flac:
            "flac"
        case .wavpack:
            "wavpack"
        }
    }

    var isLossless: Bool {
        switch self {
        case .flac, .wavpack:
            true
        case .mp3, .ogg, .opus:
            false
        }
    }
}

enum VideoOutputContainer: String, CaseIterable, Codable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4:
            "MP4"
        case .mov:
            "MOV"
        }
    }

    var fileExtension: String { rawValue }

    var detail: String {
        switch self {
        case .mp4:
            "Best default for sharing HEVC files across Apple devices and modern players."
        case .mov:
            "Useful when staying close to camera-original QuickTime workflows."
        }
    }
}

enum HEVCVideoPreset: String, CaseIterable, Codable, Identifiable {
    case compact1080p
    case balanced1080p
    case compact4k
    case balanced4k
    case main10
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact1080p:
            "1080p Compact"
        case .balanced1080p:
            "1080p Balanced"
        case .compact4k:
            "4K Compact"
        case .balanced4k:
            "4K Balanced"
        case .main10:
            "HEVC 10-bit"
        case .custom:
            "Custom"
        }
    }

    var detail: String {
        switch self {
        case .compact1080p:
            "Lower bitrate 8-bit HEVC capped at 1080p for smaller exports."
        case .balanced1080p:
            "General-purpose 8-bit HEVC capped at 1080p."
        case .compact4k:
            "Smaller 8-bit HEVC capped at 4K."
        case .balanced4k:
            "Higher-bitrate 8-bit HEVC capped at 4K."
        case .main10:
            "10-bit HEVC Main10 using p010 output for sources that benefit from extra precision."
        case .custom:
            "Choose a manual target bitrate."
        }
    }

    var defaultBitrateKbps: Int {
        switch self {
        case .compact1080p:
            4_000
        case .balanced1080p:
            7_000
        case .compact4k:
            14_000
        case .balanced4k:
            22_000
        case .main10:
            12_000
        case .custom:
            8_000
        }
    }

    var bitDepth: Int {
        switch self {
        case .main10:
            10
        case .compact1080p, .balanced1080p, .compact4k, .balanced4k, .custom:
            8
        }
    }

    var defaultScaleMode: VideoScaleMode {
        switch self {
        case .compact1080p, .balanced1080p:
            .max1080p
        case .compact4k, .balanced4k:
            .max4k
        case .main10, .custom:
            .source
        }
    }
}

enum VideoAudioMode: String, CaseIterable, Codable, Identifiable {
    case copy
    case aac192
    case aac320

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy:
            "Copy"
        case .aac192:
            "AAC 192 kbps"
        case .aac320:
            "AAC 320 kbps"
        }
    }

    var detail: String {
        switch self {
        case .copy:
            "Keep the source audio stream without re-encoding."
        case .aac192:
            "Re-encode audio to broadly compatible AAC at 192 kbps."
        case .aac320:
            "Re-encode audio to higher-bitrate AAC at 320 kbps."
        }
    }
}

enum VideoScaleMode: String, CaseIterable, Codable, Identifiable {
    case source
    case max1080p
    case max4k

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:
            "Source"
        case .max1080p:
            "1080p max"
        case .max4k:
            "4K max"
        }
    }

    var detail: String {
        switch self {
        case .source:
            "Keep the source pixel dimensions."
        case .max1080p:
            "Downscale larger sources to fit within 1920x1080. Smaller sources are not upscaled."
        case .max4k:
            "Downscale larger sources to fit within 3840x2160. Smaller sources are not upscaled."
        }
    }

    var maxSize: (width: Int, height: Int)? {
        switch self {
        case .source:
            nil
        case .max1080p:
            (width: 1_920, height: 1_080)
        case .max4k:
            (width: 3_840, height: 2_160)
        }
    }

    var usesSoftwareScale: Bool {
        maxSize != nil
    }
}

enum VideoHardwareDecodeMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            "Auto"
        case .on:
            "Prefer"
        case .off:
            "Off"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            "Ask FFmpeg to use VideoToolbox hardware decode for supported sources."
        case .on:
            "Prefer VideoToolbox hardware decode for this job."
        case .off:
            "Use FFmpeg's normal decoder path."
        }
    }

    var usesVideoToolbox: Bool {
        switch self {
        case .auto, .on:
            true
        case .off:
            false
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

enum MP3EncodingMode: String, CaseIterable, Codable, Identifiable {
    case vbr
    case cbr
    case abr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vbr:
            "VBR"
        case .cbr:
            "CBR"
        case .abr:
            "ABR"
        }
    }

    var detail: String {
        switch self {
        case .vbr:
            "Variable bitrate. Best default for quality and file size."
        case .cbr:
            "Constant bitrate. Predictable file size and broad compatibility."
        case .abr:
            "Average bitrate. Targets a size while allowing quality to vary."
        }
    }
}

enum MP3EncodingOptions {
    static let bitrateKbps = [128, 160, 192, 224, 256, 320]
    static let vbrQualities = Array(0...9)

    static func vbrQualityLabel(_ quality: Int) -> String {
        switch quality {
        case 0:
            "V0 - highest"
        case 1:
            "V1 - very high"
        case 2:
            "V2 - excellent"
        case 3:
            "V3 - high"
        case 4:
            "V4 - good"
        case 5:
            "V5 - balanced"
        case 6:
            "V6 - compact"
        case 7:
            "V7 - smaller"
        case 8:
            "V8 - low"
        default:
            "V9 - smallest"
        }
    }
}

enum OggEncodingOptions {
    enum Mode: String, CaseIterable, Codable, Identifiable {
        case bitrate
        case quality

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bitrate:
                "Bitrate"
            case .quality:
                "Quality"
            }
        }

        var detail: String {
            switch self {
            case .bitrate:
                "Target a total Vorbis audio stream bitrate, not a per-channel bitrate."
            case .quality:
                "Use Vorbis VBR quality scale. Higher values keep more detail, but the displayed bitrate still depends on the source."
            }
        }
    }

    static let bitrateKbps = [64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
    static let qualities = Array(0...10)

    static func qualityLabel(_ quality: Int) -> String {
        switch quality {
        case 0:
            "Q0 - smallest"
        case 1:
            "Q1 - compact"
        case 2:
            "Q2 - light"
        case 3:
            "Q3 - fair"
        case 4:
            "Q4 - balanced"
        case 5:
            "Q5 - good"
        case 6:
            "Q6 - high"
        case 7:
            "Q7 - very high"
        case 8:
            "Q8 - excellent"
        case 9:
            "Q9 - near lossless"
        default:
            "Q10 - largest"
        }
    }
}

enum OpusEncodingOptions {
    enum RateMode: String, CaseIterable, Codable, Identifiable {
        case vbr
        case constrained
        case cbr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .vbr:
                "VBR"
            case .constrained:
                "CVBR"
            case .cbr:
                "CBR"
            }
        }

        var ffmpegValue: String {
            switch self {
            case .vbr:
                "on"
            case .constrained:
                "constrained"
            case .cbr:
                "off"
            }
        }

        var detail: String {
            switch self {
            case .vbr:
                "Variable bitrate. Best quality-to-size behavior."
            case .constrained:
                "Constrained VBR. More predictable network-style bitrate."
            case .cbr:
                "Constant bitrate. Most predictable stream size."
            }
        }
    }

    static let bitrateKbps = [64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
}

enum FLACEncodingOptions {
    static let maximumChannelCount = 8
    static let compressionLevels = Array(0...12)

    static func compressionLevelLabel(_ level: Int) -> String {
        switch level {
        case 0:
            "Level 0 - fastest"
        case 1...4:
            "Level \(level) - fast"
        case 5:
            "Level 5 - default"
        case 6...8:
            "Level \(level) - smaller"
        case 9...11:
            "Level \(level) - very small"
        default:
            "Level 12 - maximum"
        }
    }
}

enum WavPackEncodingOptions {
    static let compatibleNamedChannelCount = 18
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

struct EncodingSettingsSnapshot {
    let ffmpegURL: URL
    let useLibVorbis: Bool
    let encodingWorkflow: EncodingWorkflow
    let outputFormat: AudioOutputFormat
    let videoOutputContainer: VideoOutputContainer
    let hevcPreset: HEVCVideoPreset
    let customVideoBitrateKbps: Int
    let videoScaleMode: VideoScaleMode
    let videoAudioMode: VideoAudioMode
    let videoHardwareDecodeMode: VideoHardwareDecodeMode
    let mp3Mode: MP3EncodingMode
    let vbrQuality: Int
    let cbrBitrateKbps: Int
    let abrBitrateKbps: Int
    let oggMode: OggEncodingOptions.Mode
    let oggQuality: Int
    let oggBitrateKbps: Int
    let opusRateMode: OpusEncodingOptions.RateMode
    let opusBitrateKbps: Int
    let flacCompressionLevel: Int
    let splitOversizedMultichannel: Bool
    let ffmpegThreads: Int
    let overwriteExisting: Bool
    let parallelJobs: Int

    var videoBitrateKbps: Int {
        hevcPreset == .custom ? customVideoBitrateKbps : hevcPreset.defaultBitrateKbps
    }

    var summary: String {
        if encodingWorkflow == .video {
            return "\(hevcPreset.title) HEVC \(videoBitrateKbps) kbps \(videoOutputContainer.title), \(videoScaleMode.title), audio \(videoAudioMode.title)"
        }

        return switch outputFormat {
        case .mp3:
            switch mp3Mode {
            case .vbr:
                "MP3 VBR \(MP3EncodingOptions.vbrQualityLabel(vbrQuality))"
            case .cbr:
                "MP3 CBR \(cbrBitrateKbps) kbps"
            case .abr:
                "MP3 ABR \(abrBitrateKbps) kbps"
            }
        case .ogg:
            switch oggMode {
            case .bitrate:
                "Ogg Vorbis \(oggBitrateKbps) kbps"
            case .quality:
                "Ogg Vorbis \(OggEncodingOptions.qualityLabel(oggQuality))"
            }
        case .opus:
            "Opus \(opusBitrateKbps) kbps \(opusRateMode.title)"
        case .flac:
            splitOversizedMultichannel
                ? "FLAC \(FLACEncodingOptions.compressionLevelLabel(flacCompressionLevel)) with multichannel split"
                : "FLAC \(FLACEncodingOptions.compressionLevelLabel(flacCompressionLevel))"
        case .wavpack:
            splitOversizedMultichannel
                ? "WavPack lossless with multichannel split"
                : "WavPack lossless"
        }
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

struct AudioEncodingPresetSettings: Codable, Hashable {
    var outputFormat: AudioOutputFormat
    var mp3Mode: MP3EncodingMode
    var vbrQuality: Int
    var cbrBitrateKbps: Int
    var abrBitrateKbps: Int
    var oggMode: OggEncodingOptions.Mode
    var oggQuality: Int
    var oggBitrateKbps: Int
    var opusRateMode: OpusEncodingOptions.RateMode
    var opusBitrateKbps: Int
    var flacCompressionLevel: Int
    var splitOversizedMultichannel: Bool

    var summary: String {
        let snapshot = EncodingSettingsSnapshot(
            ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"),
            useLibVorbis: true,
            encodingWorkflow: .audio,
            outputFormat: outputFormat,
            videoOutputContainer: .mp4,
            hevcPreset: .balanced1080p,
            customVideoBitrateKbps: HEVCVideoPreset.balanced1080p.defaultBitrateKbps,
            videoScaleMode: .max1080p,
            videoAudioMode: .copy,
            videoHardwareDecodeMode: .auto,
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
            ffmpegThreads: 0,
            overwriteExisting: false,
            parallelJobs: 1
        )
        return snapshot.summary
    }
}

struct VideoEncodingPresetSettings: Codable, Hashable {
    var outputContainer: VideoOutputContainer
    var hevcPreset: HEVCVideoPreset
    var customBitrateKbps: Int
    var scaleMode: VideoScaleMode
    var audioMode: VideoAudioMode
    var hardwareDecodeMode: VideoHardwareDecodeMode

    init(
        outputContainer: VideoOutputContainer,
        hevcPreset: HEVCVideoPreset,
        customBitrateKbps: Int,
        scaleMode: VideoScaleMode? = nil,
        audioMode: VideoAudioMode,
        hardwareDecodeMode: VideoHardwareDecodeMode = .auto
    ) {
        self.outputContainer = outputContainer
        self.hevcPreset = hevcPreset
        self.customBitrateKbps = customBitrateKbps
        self.scaleMode = scaleMode ?? hevcPreset.defaultScaleMode
        self.audioMode = audioMode
        self.hardwareDecodeMode = hardwareDecodeMode
    }

    private enum CodingKeys: String, CodingKey {
        case outputContainer
        case hevcPreset
        case customBitrateKbps
        case scaleMode
        case audioMode
        case hardwareDecodeMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputContainer = try container.decode(VideoOutputContainer.self, forKey: .outputContainer)
        hevcPreset = try container.decode(HEVCVideoPreset.self, forKey: .hevcPreset)
        customBitrateKbps = try container.decode(Int.self, forKey: .customBitrateKbps)
        scaleMode =
            try container.decodeIfPresent(VideoScaleMode.self, forKey: .scaleMode)
            ?? hevcPreset.defaultScaleMode
        audioMode = try container.decode(VideoAudioMode.self, forKey: .audioMode)
        hardwareDecodeMode =
            try container.decodeIfPresent(VideoHardwareDecodeMode.self, forKey: .hardwareDecodeMode)
            ?? .auto
    }

    var summary: String {
        let bitrate = hevcPreset == .custom ? customBitrateKbps : hevcPreset.defaultBitrateKbps
        return "\(hevcPreset.title) HEVC \(bitrate) kbps \(outputContainer.title), \(scaleMode.title), audio \(audioMode.title), decode \(hardwareDecodeMode.title)"
    }
}

struct EncodingPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var workflow: EncodingWorkflow
    var audio: AudioEncodingPresetSettings?
    var video: VideoEncodingPresetSettings?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        workflow: EncodingWorkflow,
        audio: AudioEncodingPresetSettings? = nil,
        video: VideoEncodingPresetSettings? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workflow = workflow
        self.audio = audio
        self.video = video
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var summary: String {
        switch workflow {
        case .audio:
            audio?.summary ?? "Audio preset"
        case .video:
            video?.summary ?? "Video preset"
        }
    }
}

struct EncodingPresetDocument: Codable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var presets: [EncodingPreset]
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
