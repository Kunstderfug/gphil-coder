import Foundation

enum AudioFormat {
    static let inputExtensions: Set<String> = Set(InputAudioFormat.allCases.flatMap(\.fileExtensions))
    static let readableInputList = readableList(for: inputExtensions)

    static func readableList(for extensions: Set<String>) -> String {
        guard !extensions.isEmpty else { return "None" }
        return extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }
}

enum FFmpegSourcePreference: String, CaseIterable, Identifiable {
    case bundled
    case system

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
        }
    }
}

enum AudioOutputFormat: String, CaseIterable, Identifiable {
    case mp3
    case ogg
    case opus
    case flac

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

enum MP3EncodingMode: String, CaseIterable, Identifiable {
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
    enum Mode: String, CaseIterable, Identifiable {
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
    enum RateMode: String, CaseIterable, Identifiable {
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

    func outputFileName(for format: AudioOutputFormat) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let outputBaseName = url.pathExtension.lowercased() == format.fileExtension
            ? "\(baseName)-encoded"
            : baseName
        return outputBaseName + "." + format.fileExtension
    }
}

struct EncodeJob: Identifiable {
    let id = UUID()
    let item: AudioInputItem
    let outputURL: URL
    var state: JobState = .queued
    var message: String = ""
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
    let outputFormat: AudioOutputFormat
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
    let ffmpegThreads: Int
    let overwriteExisting: Bool
    let parallelJobs: Int

    var summary: String {
        switch outputFormat {
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
            "FLAC \(FLACEncodingOptions.compressionLevelLabel(flacCompressionLevel))"
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
    var outputMode: String?
    var exportFolderPath: String?
    var selectedInputExtensions: [String]?
    var preserveSubfolders: Bool?
    var overwriteExisting: Bool?
    var outputFormat: String?
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
    var parallelJobs: Int?
    var ffmpegThreads: Int?
}

struct QueueInput: Codable {
    let urlPath: String
    let sourceRootPath: String?
    let relativeDirectory: String?
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
            parts.append("filtered \(unsupported) unsupported item\(unsupported == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No compatible audio files found." : parts.joined(separator: ", ") + "."
    }
}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
