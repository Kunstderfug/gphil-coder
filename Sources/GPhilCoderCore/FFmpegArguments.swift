import Foundation

// Pure FFmpeg argument builders, parsers, and the error types they share.
// These have no Process, FileManager, Bundle, or UI dependencies and live in
// Core so they can be unit-tested without the App target. The App-side
// FFmpegEncoder orchestrator calls into these free functions.

/// Errors raised while locating FFmpeg, building encode arguments, or running
/// an encode. Surfaced via `LocalizedError` so callers can show
/// `errorDescription` directly.
public enum FFmpegToolError: LocalizedError, Equatable {
    case notFound
    case unsupportedOggBitrate
    case unsupportedFLACChannelCount(Int)
    case unsupportedWavPackChannelCount(Int)
    case outputWouldOverwriteInput
    case processFailed(status: Int32, output: String)
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "FFmpeg was not found. Install it with Homebrew or place ffmpeg in /opt/homebrew/bin or /usr/local/bin."
        case .unsupportedOggBitrate:
            return "Ogg bitrate mode requires FFmpeg with the libvorbis encoder. Use Ogg quality mode or install an FFmpeg build with libvorbis."
        case .unsupportedFLACChannelCount(let count):
            return "FLAC supports up to 8 channels, but this source has \(count). Enable oversized multichannel splitting, use WavPack, or downmix before exporting to FLAC."
        case .unsupportedWavPackChannelCount(let count):
            return "WavPack can store very large channel counts, but common apps only handle the 18 standard named speaker channels reliably. This source has \(count) channels, so enable oversized multichannel splitting, export to WAV/RF64/W64, or split stems for DAW-compatible archival."
        case .outputWouldOverwriteInput:
            return "Output path matches the source file. Encoding was blocked to protect the original."
        case let .processFailed(status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "FFmpeg exited with status \(status)." : trimmed
        case let .couldNotStart(message):
            return message
        }
    }
}

/// A non-fatal skip reason: the output file already exists and the user did
/// not request an overwrite.
public enum EncodeSkipError: LocalizedError, Equatable {
    case outputExists

    public var errorDescription: String? {
        switch self {
        case .outputExists:
            "Output already exists."
        }
    }
}

/// Limits used when splitting oversized multichannel sources into multiple
/// DAW-compatible files. WAV is effectively unlimited, so splitting is only
/// applied to FLAC (capped at the FLAC channel limit) and WavPack (grouped to
/// stay within the standard named-speaker count).
public enum MultichannelSplitOptions {
    public static let wavPackGroupSize = 10
}

/// A parsed ffmpeg progress line, used for live throughput display.
public struct FFmpegProgressSnapshot: Sendable, Equatable {
    public let fps: String?
    public let speed: String?
    public let fractionCompleted: Double?

    public init(fps: String?, speed: String?, fractionCompleted: Double? = nil) {
        self.fps = fps
        self.speed = speed
        self.fractionCompleted = fractionCompleted
    }

    public var message: String {
        var parts: [String] = []
        if let fps, !fps.isEmpty {
            parts.append("\(fps) fps")
        }
        if let speed, !speed.isEmpty {
            parts.append("\(speed) realtime")
        }
        return parts.isEmpty ? "Encoding..." : "Encoding... " + parts.joined(separator: ", ")
    }

    /// Extracts the most recent fps/speed pair from a chunk of ffmpeg output.
    /// Returns nil when no progress line is present.
    public static func parse(from text: String, duration: TimeInterval? = nil) -> FFmpegProgressSnapshot? {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n")
            .map(String.init)
            .reversed()

        for line in lines where line.contains("fps=") || line.contains("speed=") {
            let fps = firstRegexValue(in: line, pattern: #"fps=\s*([0-9.]+)"#)
            let speed = firstRegexValue(in: line, pattern: #"speed=\s*([0-9.]+x)"#)
            let elapsed = firstRegexValue(in: line, pattern: #"time=\s*([0-9:.]+)"#)
                .flatMap(parseTimestamp)
            let fractionCompleted = progressFraction(elapsed: elapsed, duration: duration)
            if fps != nil || speed != nil || fractionCompleted != nil {
                return FFmpegProgressSnapshot(
                    fps: fps,
                    speed: speed,
                    fractionCompleted: fractionCompleted
                )
            }
        }

        return nil
    }

    public static func parseDuration(from text: String) -> TimeInterval? {
        firstRegexValue(in: text, pattern: #"Duration:\s*([0-9:.]+)"#)
            .flatMap(parseTimestamp)
    }

    private static func firstRegexValue(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[valueRange])
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func progressFraction(elapsed: TimeInterval?, duration: TimeInterval?) -> Double? {
        guard let elapsed, let duration, duration > 0 else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }
}

// MARK: - Audio argument building

/// Builds the audio codec arguments (`-codec:a`, bitrate/quality, etc.) for an
/// encode described by `settings`. Throws `.unsupportedOggBitrate` when Ogg
/// bitrate mode is requested but the available FFmpeg lacks libvorbis.
public func ffmpegCodecArguments(for settings: EncodingSettingsSnapshot) throws -> [String] {
    var arguments: [String] = []

    switch settings.outputFormat {
    case .mp3:
        arguments.append(contentsOf: ["-codec:a", "libmp3lame"])

        switch settings.mp3Mode {
        case .vbr:
            arguments.append(contentsOf: ["-q:a", "\(settings.vbrQuality)"])
        case .cbr:
            arguments.append(contentsOf: ["-b:a", "\(settings.cbrBitrateKbps)k"])
        case .abr:
            arguments.append(contentsOf: ["-abr", "1", "-b:a", "\(settings.abrBitrateKbps)k"])
        }

    case .ogg:
        if settings.oggMode == .bitrate, !settings.useLibVorbis {
            throw FFmpegToolError.unsupportedOggBitrate
        }

        arguments.append(contentsOf: [
            "-codec:a", settings.useLibVorbis ? "libvorbis" : "vorbis",
            "-ac", "2"
        ])

        switch settings.oggMode {
        case .bitrate:
            arguments.append(contentsOf: ["-b:a", "\(settings.oggBitrateKbps)k"])
        case .quality:
            arguments.append(contentsOf: ["-qscale:a", "\(settings.oggQuality)"])
        }

        arguments.append(contentsOf: ["-strict", "-2"])

    case .opus:
        arguments.append(contentsOf: [
            "-codec:a", "libopus",
            "-b:a", "\(settings.opusBitrateKbps)k",
            "-vbr", settings.opusRateMode.ffmpegValue,
            "-compression_level", "10"
        ])

    case .flac:
        arguments.append(contentsOf: [
            "-codec:a", "flac",
            "-compression_level", "\(settings.flacCompressionLevel)"
        ])

    case .wavpack:
        arguments.append(contentsOf: ["-codec:a", "wavpack"])
    }

    return arguments
}

// MARK: - Multichannel splitting

/// Whether `channelCount` exceeds the safe per-format limit and the user has
/// enabled oversized multichannel splitting.
public func ffmpegShouldSplitMultichannel(
    _ channelCount: Int,
    settings: EncodingSettingsSnapshot
) -> Bool {
    guard settings.splitOversizedMultichannel else { return false }
    switch settings.outputFormat {
    case .flac:
        return channelCount > FLACEncodingOptions.maximumChannelCount
    case .wavpack:
        return channelCount > WavPackEncodingOptions.compatibleNamedChannelCount
    case .mp3, .ogg, .opus:
        return false
    }
}

/// Splits `channelCount` channels into consecutive groups, each no larger than
/// the output format's channel limit. WavPack merges the final two groups when
/// the combined count still fits within the standard named-speaker count, so
/// the last file isn't left with one or two stragglers.
public func ffmpegChannelGroups(
    for channelCount: Int,
    settings: EncodingSettingsSnapshot
) -> [(start: Int, end: Int)] {
    let groupSize =
        settings.outputFormat == .flac
        ? FLACEncodingOptions.maximumChannelCount
        : MultichannelSplitOptions.wavPackGroupSize
    var groups = stride(from: 1, through: channelCount, by: groupSize).map {
        start in
        (start: start, end: min(start + groupSize - 1, channelCount))
    }

    if settings.outputFormat == .wavpack,
        groups.count >= 2,
        let previous = groups.dropLast().last,
        let last = groups.last,
        last.end - previous.start + 1 <= WavPackEncodingOptions.compatibleNamedChannelCount
    {
        groups.removeLast(2)
        groups.append((start: previous.start, end: last.end))
    }

    return groups
}

/// The ffmpeg `pan` filter that maps source channels in `group` to the standard
/// named speaker layout (FL, FR, FC, ...).
public func ffmpegPanFilter(for group: (start: Int, end: Int)) -> String {
    let outputChannelCount = group.end - group.start + 1
    if outputChannelCount == 1 {
        return "pan=mono|c0=c\(group.start - 1)"
    }

    let channels = Array(FFmpegPanChannelNames.standard.prefix(outputChannelCount))
    let mappings = channels.enumerated().map { outputIndex, channelName in
        "\(channelName)=c\(group.start - 1 + outputIndex)"
    }
    return "pan=\(channels.joined(separator: "+"))|" + mappings.joined(separator: "|")
}

/// Standard ffmpeg channel-layout names in channel order, used by the pan
/// filter when mapping multichannel groups.
public enum FFmpegPanChannelNames {
    public static let standard = [
        "FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC", "BC",
        "SL", "SR", "TC", "TFL", "TFC", "TFR", "TBL", "TBC", "TBR"
    ]
}

// MARK: - Video argument building

/// Builds the video codec arguments (hevc_videotoolbox, bitrate, scale, pixel
/// format) for a video encode described by `settings`.
public func ffmpegVideoCodecArguments(for settings: EncodingSettingsSnapshot) -> [String] {
    var arguments: [String] = []

    if let scaleFilter = ffmpegVideoScaleFilter(for: settings.videoScaleMode) {
        arguments.append(contentsOf: ["-vf", scaleFilter])
    }

    arguments.append(contentsOf: [
        "-c:v", "hevc_videotoolbox",
        "-b:v", "\(settings.videoBitrateKbps)k",
        "-maxrate", "\(settings.videoBitrateKbps)k",
        "-bufsize", "\(settings.videoBitrateKbps * 2)k",
        "-tag:v", "hvc1",
        "-allow_sw", "0",
        "-prio_speed", "1",
        "-realtime", "1",
        "-power_efficient", "0"
    ])

    if settings.hevcPreset.bitDepth == 10 {
        arguments.append(contentsOf: ["-pix_fmt", "p010le", "-profile:v", "main10"])
    } else {
        arguments.append(contentsOf: ["-pix_fmt", "yuv420p"])
    }

    return arguments
}

/// The ffmpeg `-vf scale=` filter string for `scaleMode`, or nil when no
/// resolution cap is set.
public func ffmpegVideoScaleFilter(for scaleMode: VideoScaleMode) -> String? {
    guard let maxSize = scaleMode.maxSize else { return nil }
    return
        "scale=w=min(\(maxSize.width)\\,iw):h=min(\(maxSize.height)\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2"
}

// MARK: - ffprobe parsing

/// Pure parsing of the audio channel count from `ffprobe`/`ffmpeg -i` output.
/// Recognizes explicit `N channels`, compact `Nch`, and the channel-layout
/// field (e.g. "5.1(side)", "stereo"). Returns nil when nothing is recognized.
public func parseAudioChannelCount(from output: String) -> Int? {
    let audioLines = output
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.contains("Audio:") }

    for line in audioLines {
        if let explicit = FFmpegProbeParsing.firstRegexInt(in: line, pattern: #"(\d+)\s+channels"#) {
            return explicit
        }
        if let compact = FFmpegProbeParsing.firstRegexInt(in: line, pattern: #"(\d+)ch(?:\s|$)"#) {
            return compact
        }

        if let layout = FFmpegProbeParsing.audioLayoutField(from: line),
            let count = FFmpegProbeParsing.channelCount(forLayout: layout)
        {
            return count
        }
    }

    return nil
}

/// Internal parsing helpers for `parseAudioChannelCount`, namespaced so they
/// don't pollute the Core API surface.
enum FFmpegProbeParsing {
    static func audioLayoutField(from line: String) -> String? {
        let fields = line.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let sampleRateIndex = fields.firstIndex(where: { $0.contains(" Hz") }),
            fields.indices.contains(sampleRateIndex + 1)
        else {
            return nil
        }
        return fields[sampleRateIndex + 1]
    }

    static func channelCount(forLayout layout: String) -> Int? {
        let normalized = layout.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "", options: .regularExpression)
        if let known = knownLayoutChannelCounts[normalized] {
            return known
        }

        let parts = normalized.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.compactMap { Int($0) }.reduce(0, +)
    }

    static func firstRegexInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    static let knownLayoutChannelCounts: [String: Int] = [
        "mono": 1,
        "stereo": 2,
        "2.1": 3,
        "3.0": 3,
        "3.0back": 3,
        "4.0": 4,
        "quad": 4,
        "quadside": 4,
        "3.1": 4,
        "5.0": 5,
        "5.0side": 5,
        "4.1": 5,
        "5.1": 6,
        "5.1side": 6,
        "6.0": 6,
        "6.0front": 6,
        "hexagonal": 6,
        "6.1": 7,
        "6.1back": 7,
        "6.1front": 7,
        "7.0": 7,
        "7.0front": 7,
        "7.1": 8,
        "7.1wide": 8,
        "7.1wideside": 8,
        "octagonal": 8
    ]
}
