import Foundation

// Encoding and preset model types. These are pure Foundation / Codable value
// types shared between the app and the test target, so they live in Core.

public enum EncodingWorkflow: String, CaseIterable, Codable, Identifiable {
    case audio
    case video

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .audio:
            "Audio"
        case .video:
            "Video"
        }
    }

    public var queueNoun: String {
        switch self {
        case .audio:
            "audio file"
        case .video:
            "video file"
        }
    }

    public var symbolName: String {
        switch self {
        case .audio:
            "waveform"
        case .video:
            "film"
        }
    }
}

public enum AudioOutputFormat: String, CaseIterable, Codable, Identifiable {
    case mp3
    case ogg
    case opus
    case flac
    case wavpack

    public var id: String { rawValue }

    public var title: String {
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

    public var fileExtension: String {
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

    public var detail: String {
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

    public var codecName: String {
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

    public var isLossless: Bool {
        switch self {
        case .flac, .wavpack:
            true
        case .mp3, .ogg, .opus:
            false
        }
    }
}

public enum VideoOutputContainer: String, CaseIterable, Codable, Identifiable {
    case mp4
    case mov

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4:
            "MP4"
        case .mov:
            "MOV"
        }
    }

    public var fileExtension: String { rawValue }

    public var detail: String {
        switch self {
        case .mp4:
            "Best default for sharing HEVC files across Apple devices and modern players."
        case .mov:
            "Useful when staying close to camera-original QuickTime workflows."
        }
    }
}

public enum HEVCVideoPreset: String, CaseIterable, Codable, Identifiable {
    case compact1080p
    case balanced1080p
    case compact4k
    case balanced4k
    case main10
    case custom

    public var id: String { rawValue }

    public var title: String {
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

    public var detail: String {
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

    public var defaultBitrateKbps: Int {
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

    public var bitDepth: Int {
        switch self {
        case .main10:
            10
        case .compact1080p, .balanced1080p, .compact4k, .balanced4k, .custom:
            8
        }
    }

    public var defaultScaleMode: VideoScaleMode {
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

public enum VideoAudioMode: String, CaseIterable, Codable, Identifiable {
    case copy
    case aac192
    case aac320

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy:
            "Copy"
        case .aac192:
            "AAC 192 kbps"
        case .aac320:
            "AAC 320 kbps"
        }
    }

    public var detail: String {
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

public enum VideoScaleMode: String, CaseIterable, Codable, Identifiable {
    case source
    case max1080p
    case max4k

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source:
            "Source"
        case .max1080p:
            "1080p max"
        case .max4k:
            "4K max"
        }
    }

    public var detail: String {
        switch self {
        case .source:
            "Keep the source pixel dimensions."
        case .max1080p:
            "Downscale larger sources to fit within 1920x1080. Smaller sources are not upscaled."
        case .max4k:
            "Downscale larger sources to fit within 3840x2160. Smaller sources are not upscaled."
        }
    }

    public var maxSize: (width: Int, height: Int)? {
        switch self {
        case .source:
            nil
        case .max1080p:
            (width: 1_920, height: 1_080)
        case .max4k:
            (width: 3_840, height: 2_160)
        }
    }

    public var usesSoftwareScale: Bool {
        maxSize != nil
    }
}

public enum VideoHardwareDecodeMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case on
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto:
            "Auto"
        case .on:
            "Prefer"
        case .off:
            "Off"
        }
    }

    public var detail: String {
        switch self {
        case .auto:
            "Ask FFmpeg to use VideoToolbox hardware decode for supported sources."
        case .on:
            "Prefer VideoToolbox hardware decode for this job."
        case .off:
            "Use FFmpeg's normal decoder path."
        }
    }

    public var usesVideoToolbox: Bool {
        switch self {
        case .auto, .on:
            true
        case .off:
            false
        }
    }
}

public enum MP3EncodingMode: String, CaseIterable, Codable, Identifiable {
    case vbr
    case cbr
    case abr

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vbr:
            "VBR"
        case .cbr:
            "CBR"
        case .abr:
            "ABR"
        }
    }

    public var detail: String {
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

public enum MP3EncodingOptions {
    public static let bitrateKbps = [128, 160, 192, 224, 256, 320]
    public static let vbrQualities = Array(0...9)

    public static func vbrQualityLabel(_ quality: Int) -> String {
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

public enum OggEncodingOptions {
    public enum Mode: String, CaseIterable, Codable, Identifiable {
        case bitrate
        case quality

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .bitrate:
                "Bitrate"
            case .quality:
                "Quality"
            }
        }

        public var detail: String {
            switch self {
            case .bitrate:
                "Target a total Vorbis audio stream bitrate, not a per-channel bitrate."
            case .quality:
                "Use Vorbis VBR quality scale. Higher values keep more detail, but the displayed bitrate still depends on the source."
            }
        }
    }

    public static let bitrateKbps = [64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
    public static let qualities = Array(0...10)

    public static func qualityLabel(_ quality: Int) -> String {
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

public enum OpusEncodingOptions {
    public enum RateMode: String, CaseIterable, Codable, Identifiable {
        case vbr
        case constrained
        case cbr

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .vbr:
                "VBR"
            case .constrained:
                "CVBR"
            case .cbr:
                "CBR"
            }
        }

        public var ffmpegValue: String {
            switch self {
            case .vbr:
                "on"
            case .constrained:
                "constrained"
            case .cbr:
                "off"
            }
        }

        public var detail: String {
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

    public static let bitrateKbps = [64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
}

public enum FLACEncodingOptions {
    public static let maximumChannelCount = 8
    public static let compressionLevels = Array(0...12)

    public static func compressionLevelLabel(_ level: Int) -> String {
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

public enum WavPackEncodingOptions {
    public static let compatibleNamedChannelCount = 18
}

public struct EncodingSettingsSnapshot {
    public let ffmpegURL: URL
    public let useLibVorbis: Bool
    public let encodingWorkflow: EncodingWorkflow
    public let outputFormat: AudioOutputFormat
    public let videoOutputContainer: VideoOutputContainer
    public let hevcPreset: HEVCVideoPreset
    public let customVideoBitrateKbps: Int
    public let videoScaleMode: VideoScaleMode
    public let videoAudioMode: VideoAudioMode
    public let videoHardwareDecodeMode: VideoHardwareDecodeMode
    public let mp3Mode: MP3EncodingMode
    public let vbrQuality: Int
    public let cbrBitrateKbps: Int
    public let abrBitrateKbps: Int
    public let oggMode: OggEncodingOptions.Mode
    public let oggQuality: Int
    public let oggBitrateKbps: Int
    public let opusRateMode: OpusEncodingOptions.RateMode
    public let opusBitrateKbps: Int
    public let flacCompressionLevel: Int
    public let splitOversizedMultichannel: Bool
    public let ffmpegThreads: Int
    public let overwriteExisting: Bool
    public let parallelJobs: Int

    public init(
        ffmpegURL: URL,
        useLibVorbis: Bool,
        encodingWorkflow: EncodingWorkflow,
        outputFormat: AudioOutputFormat,
        videoOutputContainer: VideoOutputContainer,
        hevcPreset: HEVCVideoPreset,
        customVideoBitrateKbps: Int,
        videoScaleMode: VideoScaleMode,
        videoAudioMode: VideoAudioMode,
        videoHardwareDecodeMode: VideoHardwareDecodeMode,
        mp3Mode: MP3EncodingMode,
        vbrQuality: Int,
        cbrBitrateKbps: Int,
        abrBitrateKbps: Int,
        oggMode: OggEncodingOptions.Mode,
        oggQuality: Int,
        oggBitrateKbps: Int,
        opusRateMode: OpusEncodingOptions.RateMode,
        opusBitrateKbps: Int,
        flacCompressionLevel: Int,
        splitOversizedMultichannel: Bool,
        ffmpegThreads: Int,
        overwriteExisting: Bool,
        parallelJobs: Int
    ) {
        self.ffmpegURL = ffmpegURL
        self.useLibVorbis = useLibVorbis
        self.encodingWorkflow = encodingWorkflow
        self.outputFormat = outputFormat
        self.videoOutputContainer = videoOutputContainer
        self.hevcPreset = hevcPreset
        self.customVideoBitrateKbps = customVideoBitrateKbps
        self.videoScaleMode = videoScaleMode
        self.videoAudioMode = videoAudioMode
        self.videoHardwareDecodeMode = videoHardwareDecodeMode
        self.mp3Mode = mp3Mode
        self.vbrQuality = vbrQuality
        self.cbrBitrateKbps = cbrBitrateKbps
        self.abrBitrateKbps = abrBitrateKbps
        self.oggMode = oggMode
        self.oggQuality = oggQuality
        self.oggBitrateKbps = oggBitrateKbps
        self.opusRateMode = opusRateMode
        self.opusBitrateKbps = opusBitrateKbps
        self.flacCompressionLevel = flacCompressionLevel
        self.splitOversizedMultichannel = splitOversizedMultichannel
        self.ffmpegThreads = ffmpegThreads
        self.overwriteExisting = overwriteExisting
        self.parallelJobs = parallelJobs
    }

    public var videoBitrateKbps: Int {
        hevcPreset == .custom ? customVideoBitrateKbps : hevcPreset.defaultBitrateKbps
    }

    public var summary: String {
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

public struct AudioEncodingPresetSettings: Codable, Hashable {
    public var outputFormat: AudioOutputFormat
    public var mp3Mode: MP3EncodingMode
    public var vbrQuality: Int
    public var cbrBitrateKbps: Int
    public var abrBitrateKbps: Int
    public var oggMode: OggEncodingOptions.Mode
    public var oggQuality: Int
    public var oggBitrateKbps: Int
    public var opusRateMode: OpusEncodingOptions.RateMode
    public var opusBitrateKbps: Int
    public var flacCompressionLevel: Int
    public var splitOversizedMultichannel: Bool

    public init(
        outputFormat: AudioOutputFormat,
        mp3Mode: MP3EncodingMode,
        vbrQuality: Int,
        cbrBitrateKbps: Int,
        abrBitrateKbps: Int,
        oggMode: OggEncodingOptions.Mode,
        oggQuality: Int,
        oggBitrateKbps: Int,
        opusRateMode: OpusEncodingOptions.RateMode,
        opusBitrateKbps: Int,
        flacCompressionLevel: Int,
        splitOversizedMultichannel: Bool
    ) {
        self.outputFormat = outputFormat
        self.mp3Mode = mp3Mode
        self.vbrQuality = vbrQuality
        self.cbrBitrateKbps = cbrBitrateKbps
        self.abrBitrateKbps = abrBitrateKbps
        self.oggMode = oggMode
        self.oggQuality = oggQuality
        self.oggBitrateKbps = oggBitrateKbps
        self.opusRateMode = opusRateMode
        self.opusBitrateKbps = opusBitrateKbps
        self.flacCompressionLevel = flacCompressionLevel
        self.splitOversizedMultichannel = splitOversizedMultichannel
    }

    public var summary: String {
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

public struct VideoEncodingPresetSettings: Codable, Hashable {
    public var outputContainer: VideoOutputContainer
    public var hevcPreset: HEVCVideoPreset
    public var customBitrateKbps: Int
    public var scaleMode: VideoScaleMode
    public var audioMode: VideoAudioMode
    public var hardwareDecodeMode: VideoHardwareDecodeMode

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public var summary: String {
        let bitrate = hevcPreset == .custom ? customBitrateKbps : hevcPreset.defaultBitrateKbps
        return "\(hevcPreset.title) HEVC \(bitrate) kbps \(outputContainer.title), \(scaleMode.title), audio \(audioMode.title), decode \(hardwareDecodeMode.title)"
    }
}

public struct EncodingPreset: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var workflow: EncodingWorkflow
    public var audio: AudioEncodingPresetSettings?
    public var video: VideoEncodingPresetSettings?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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

    public var summary: String {
        switch workflow {
        case .audio:
            audio?.summary ?? "Audio preset"
        case .video:
            video?.summary ?? "Video preset"
        }
    }
}

public struct EncodingPresetDocument: Codable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var presets: [EncodingPreset]

    public init(presets: [EncodingPreset] = []) {
        self.presets = presets
    }
}

public extension EncodingPresetDocument {
    /// Why a stored-presets blob could not be decoded.
    ///
    /// Surfaced as a typed value (instead of a silent `nil`) so callers can
    /// show the user what happened and avoid overwriting on-disk data.
    enum DecodeProblem: Error, Equatable, Sendable {
        /// The blob was written by a version newer than this code understands.
        case versionMismatch(found: Int, supported: Int)
        /// The blob exists but could not be structurally decoded.
        case corrupt(underlying: String)
    }

    /// Decodes the stored-presets blob, distinguishing a future version and
    /// corruption from an empty-but-valid state.
    ///
    /// The version envelope is read first so that a future shape change can be
    /// detected (and, eventually, migrated) before attempting a full structural
    /// decode. New migration branches go here.
    static func decode(from data: Data) -> Result<[EncodingPreset], DecodeProblem> {
        let envelopeVersion = (try? JSONDecoder().decode(
            VersionEnvelope.self, from: data))?.version
        if let version = envelopeVersion, version != Self.currentVersion {
            // Future: branch on `version` and migrate to currentVersion here.
            return .failure(.versionMismatch(found: version, supported: Self.currentVersion))
        }
        do {
            let document = try JSONDecoder().decode(EncodingPresetDocument.self, from: data)
            return .success(document.presets)
        } catch {
            return .failure(.corrupt(underlying: String(describing: error)))
        }
    }

    private struct VersionEnvelope: Codable {
        let version: Int?
    }
}

public extension EncodingPreset {
    /// The workflow-scoped selected-preset IDs after dangling references are dropped.
    struct NormalizedSelection: Equatable, Sendable {
        public var audioID: UUID?
        public var videoID: UUID?

        public init(audioID: UUID?, videoID: UUID?) {
            self.audioID = audioID
            self.videoID = videoID
        }
    }

    /// Clears selected-preset IDs that point at a missing preset or at a preset
    /// of the wrong workflow. Pure so it can be unit tested without UserDefaults.
    static func normalize(
        selectedAudioID: UUID?,
        selectedVideoID: UUID?,
        in presets: [EncodingPreset]
    ) -> NormalizedSelection {
        let audio = selectedAudioID.flatMap { id in
            presets.contains(where: { $0.id == id && $0.workflow == .audio }) ? id : nil
        }
        let video = selectedVideoID.flatMap { id in
            presets.contains(where: { $0.id == id && $0.workflow == .video }) ? id : nil
        }
        return NormalizedSelection(audioID: audio, videoID: video)
    }
}
