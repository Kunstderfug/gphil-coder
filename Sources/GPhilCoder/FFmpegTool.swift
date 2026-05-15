import Foundation

enum FFmpegToolError: LocalizedError {
    case notFound
    case unsupportedOggBitrate
    case unsupportedFLACChannelCount(Int)
    case unsupportedWavPackChannelCount(Int)
    case outputWouldOverwriteInput
    case processFailed(status: Int32, output: String)
    case couldNotStart(String)

    var errorDescription: String? {
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

struct FFmpegCapabilities {
    var hasLibVorbis = false

    static func detect(ffmpegURL: URL) -> FFmpegCapabilities {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-encoders"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return FFmpegCapabilities()
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return FFmpegCapabilities(hasLibVorbis: output.contains("libvorbis"))
    }
}

struct FFmpegLocator {
    static func locate(preference: FFmpegSourcePreference) -> URL? {
        switch preference {
        case .bundled:
            return bundledFFmpegURL()
        case .system:
            return systemFFmpegURL()
        }
    }

    static func systemFFmpegURL() -> URL? {
        if let overridePath = ProcessInfo.processInfo.environment["GPHILCODER_FFMPEG"],
            !overridePath.isEmpty
        {
            let overrideURL = URL(fileURLWithPath: overridePath)
            if FileManager.default.isExecutableFile(atPath: overrideURL.path) {
                return overrideURL
            }
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func bundledFFmpegURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("ffmpeg"),
            resourceURL.appendingPathComponent("bin/ffmpeg")
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isBundled(_ url: URL) -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        let resourcePath = resourceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let toolPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return toolPath.hasPrefix(resourcePath + "/")
    }
}

struct FFmpegEncoder {
    let ffmpegURL: URL

    func encode(input: URL, output: URL, settings: EncodingSettingsSnapshot) async throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let inputPath = input.standardizedFileURL.resolvingSymlinksInPath().path
        let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
        if inputPath == outputPath {
            throw FFmpegToolError.outputWouldOverwriteInput
        }

        let channelCount = try await FFmpegProbe.audioChannelCount(
            ffmpegURL: ffmpegURL,
            input: input
        )
        if let channelCount, shouldSplitMultichannel(channelCount, settings: settings) {
            return try await encodeSplitMultichannel(
                input: input,
                output: output,
                settings: settings,
                channelCount: channelCount
            )
        }

        if FileManager.default.fileExists(atPath: output.path), !settings.overwriteExisting {
            throw EncodeSkipError.outputExists
        }

        if settings.outputFormat == .flac,
            let channelCount,
            channelCount > FLACEncodingOptions.maximumChannelCount
        {
            throw FFmpegToolError.unsupportedFLACChannelCount(channelCount)
        }

        if settings.outputFormat == .wavpack,
            let channelCount,
            channelCount > WavPackEncodingOptions.compatibleNamedChannelCount
        {
            throw FFmpegToolError.unsupportedWavPackChannelCount(channelCount)
        }

        var arguments = [
            "-hide_banner",
            "-nostdin",
            settings.overwriteExisting ? "-y" : "-n",
            "-i", input.path,
            "-vn"
        ]

        arguments.append(contentsOf: try codecArguments(for: settings))

        if settings.ffmpegThreads > 0 {
            arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
        }

        arguments.append(output.path)

        return try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
    }

    private func encodeSplitMultichannel(
        input: URL,
        output: URL,
        settings: EncodingSettingsSnapshot,
        channelCount: Int
    ) async throws -> String {
        let groups = channelGroups(for: channelCount, settings: settings)
        let outputURLs = groups.map {
            splitOutputURL(baseURL: output, startChannel: $0.start, endChannel: $0.end)
        }
        let inputPath = input.standardizedFileURL.resolvingSymlinksInPath().path

        for outputURL in outputURLs {
            let outputPath = outputURL.standardizedFileURL.resolvingSymlinksInPath().path
            if inputPath == outputPath {
                throw FFmpegToolError.outputWouldOverwriteInput
            }
            if FileManager.default.fileExists(atPath: outputURL.path), !settings.overwriteExisting {
                throw EncodeSkipError.outputExists
            }
        }

        var outputs: [String] = []
        for (group, outputURL) in zip(groups, outputURLs) {
            var arguments = [
                "-hide_banner",
                "-nostdin",
                settings.overwriteExisting ? "-y" : "-n",
                "-i", input.path,
                "-vn",
                "-filter:a", panFilter(for: group)
            ]
            arguments.append(contentsOf: try codecArguments(for: settings))
            if settings.ffmpegThreads > 0 {
                arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
            }
            arguments.append(outputURL.path)

            let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
            let summary = output
                .split(separator: "\n")
                .map(String.init)
                .last(where: { $0.contains("audio:") || $0.contains("video:") })
                ?? "wrote \(outputURL.lastPathComponent)"
            outputs.append("ch\(group.start)-\(group.end): \(summary)")
        }

        return "Split \(channelCount) channels into \(outputs.count) file\(outputs.count == 1 ? "" : "s"). "
            + outputs.joined(separator: " ")
    }

    private func codecArguments(for settings: EncodingSettingsSnapshot) throws -> [String] {
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

    private func shouldSplitMultichannel(
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

    private func channelGroups(
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

    private func panFilter(for group: (start: Int, end: Int)) -> String {
        let outputChannelCount = group.end - group.start + 1
        if outputChannelCount == 1 {
            return "pan=mono|c0=c\(group.start - 1)"
        }

        let channels = Array(Self.standardPanChannels.prefix(outputChannelCount))
        let mappings = channels.enumerated().map { outputIndex, channelName in
            "\(channelName)=c\(group.start - 1 + outputIndex)"
        }
        return "pan=\(channels.joined(separator: "+"))|" + mappings.joined(separator: "|")
    }

    private func splitOutputURL(baseURL: URL, startChannel: Int, endChannel: Int) -> URL {
        let directory = baseURL.deletingLastPathComponent()
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension
        return directory.appendingPathComponent(
            "\(baseName)_ch\(startChannel)-\(endChannel).\(fileExtension)",
            isDirectory: false
        )
    }

    private static let standardPanChannels = [
        "FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC", "BC",
        "SL", "SR", "TC", "TFL", "TFC", "TFR", "TBL", "TBC", "TBR"
    ]
}

enum FFmpegProbe {
    static func audioChannelCount(ffmpegURL: URL, input: URL) async throws -> Int? {
        let output: String
        do {
            output = try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: ["-hide_banner", "-i", input.path]
            )
        } catch FFmpegToolError.processFailed(_, let probeOutput) {
            output = probeOutput
        }

        return parseAudioChannelCount(from: output)
    }

    static func parseAudioChannelCount(from output: String) -> Int? {
        let audioLines = output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("Audio:") }

        for line in audioLines {
            if let explicit = firstRegexInt(in: line, pattern: #"(\d+)\s+channels"#) {
                return explicit
            }
            if let compact = firstRegexInt(in: line, pattern: #"(\d+)ch(?:\s|$)"#) {
                return compact
            }

            if let layout = audioLayoutField(from: line),
                let count = channelCount(forLayout: layout)
            {
                return count
            }
        }

        return nil
    }

    private static func audioLayoutField(from line: String) -> String? {
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

    private static func channelCount(forLayout layout: String) -> Int? {
        let normalized = layout.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "", options: .regularExpression)
        if let known = knownLayoutChannelCounts[normalized] {
            return known
        }

        let parts = normalized.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.compactMap { Int($0) }.reduce(0, +)
    }

    private static func firstRegexInt(in text: String, pattern: String) -> Int? {
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

    private static let knownLayoutChannelCounts: [String: Int] = [
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

enum EncodeSkipError: LocalizedError {
    case outputExists

    var errorDescription: String? {
        switch self {
        case .outputExists:
            "Output already exists."
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        process?.terminate()
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}

enum ProcessRunner {
    static func run(executableURL: URL, arguments: [String]) async throws -> String {
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    throw CancellationError()
                }

                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let outputBuffer = OutputBuffer()
                let errorBuffer = OutputBuffer()

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    outputBuffer.append(handle.availableData)
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    errorBuffer.append(handle.availableData)
                }

                process.standardOutput = outputPipe
                process.standardError = errorPipe
                processBox.set(process)

                do {
                    try process.run()
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    throw FFmpegToolError.couldNotStart(error.localizedDescription)
                }

                process.waitUntilExit()

                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

                let combinedOutput = [outputBuffer.string, errorBuffer.string]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                if Task.isCancelled {
                    throw CancellationError()
                }

                guard process.terminationStatus == 0 else {
                    throw FFmpegToolError.processFailed(
                        status: process.terminationStatus,
                        output: combinedOutput
                    )
                }

                return combinedOutput
            }.value
        } onCancel: {
            processBox.terminate()
        }
    }
}
