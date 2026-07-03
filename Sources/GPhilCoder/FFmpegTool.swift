import Foundation
import GPhilCoderCore

struct FFmpegCapabilities {
    var hasLibVorbis = false
    var hasHEVCVideoToolbox = false

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

        return FFmpegCapabilities(
            hasLibVorbis: output.contains("libvorbis"),
            hasHEVCVideoToolbox: output.contains("hevc_videotoolbox")
        )
    }
}

struct FFmpegLocator {
    static func locate(preference: FFmpegSourcePreference) -> URL? {
        #if APP_STORE
        return bundledFFmpegURL()
        #else
        switch preference {
        case .bundled:
            return bundledFFmpegURL()
        case .system:
            return systemFFmpegURL()
        }
        #endif
    }

    static func systemFFmpegURL() -> URL? {
        #if APP_STORE
        return nil
        #else
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
        #endif
    }

    static func bundledFFmpegURL() -> URL? {
        let executableDirectoryURL = Bundle.main.executableURL?.deletingLastPathComponent()
        let resourceURL = Bundle.main.resourceURL
        let candidates = [
            executableDirectoryURL?.appendingPathComponent("ffmpeg"),
            resourceURL?.appendingPathComponent("ffmpeg"),
            resourceURL?.appendingPathComponent("bin/ffmpeg")
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isBundled(_ url: URL) -> Bool {
        let bundleDirectories = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.resourceURL
        ].compactMap { $0 }
        let toolPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return bundleDirectories.contains {
            let bundlePath = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return toolPath.hasPrefix(bundlePath + "/")
        }
    }
}

struct FFmpegEncoder {
    let ffmpegURL: URL
    let processRegistry: ProcessRegistry?

    init(ffmpegURL: URL, processRegistry: ProcessRegistry? = nil) {
        self.ffmpegURL = ffmpegURL
        self.processRegistry = processRegistry
    }

    func encode(
        input: URL,
        output: URL,
        settings: EncodingSettingsSnapshot,
        progressHandler: (@Sendable (FFmpegProgressSnapshot) -> Void)? = nil
    ) async throws -> String {
        if settings.encodingWorkflow == .video {
            return try await encodeVideo(
                input: input,
                output: output,
                settings: settings,
                progressHandler: progressHandler
            )
        }

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
            input: input,
            processRegistry: processRegistry
        )
        let inputDuration = try? await FFmpegProbe.mediaDuration(
            ffmpegURL: ffmpegURL,
            input: input,
            processRegistry: processRegistry
        )
        if let channelCount, ffmpegShouldSplitMultichannel(channelCount, settings: settings) {
            return try await encodeSplitMultichannel(
                input: input,
                output: output,
                settings: settings,
                channelCount: channelCount,
                inputDuration: inputDuration,
                progressHandler: progressHandler
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

        arguments.append(contentsOf: try ffmpegCodecArguments(for: settings))

        if settings.ffmpegThreads > 0 {
            arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
        }

        // Write to a unique temp sibling, then atomically replace the final
        // output on success. A cancelled or failed encode must never leave a
        // truncated file at the user-visible output path.
        let tempOutput = temporaryOutputURL(beside: output)
        arguments.append(tempOutput.path)

        return try await runInstallingTemp(temp: tempOutput, output: output) {
            try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: arguments,
                processRegistry: processRegistry
            ) { chunk in
                guard let progress = FFmpegProgressSnapshot.parse(
                    from: chunk,
                    duration: inputDuration
                ) else {
                    return
                }
                progressHandler?(progress)
            }
        }
    }

    private func encodeVideo(
        input: URL,
        output: URL,
        settings: EncodingSettingsSnapshot,
        progressHandler: (@Sendable (FFmpegProgressSnapshot) -> Void)?
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let inputPath = input.standardizedFileURL.resolvingSymlinksInPath().path
        let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
        if inputPath == outputPath {
            throw FFmpegToolError.outputWouldOverwriteInput
        }

        if FileManager.default.fileExists(atPath: output.path), !settings.overwriteExisting {
            throw EncodeSkipError.outputExists
        }

        var arguments = [
            "-hide_banner",
            "-nostdin",
            settings.overwriteExisting ? "-y" : "-n"
        ]

        if settings.videoHardwareDecodeMode.usesVideoToolbox {
            arguments.append(contentsOf: ["-hwaccel", "videotoolbox"])
        }

        arguments.append(contentsOf: [
            "-i", input.path,
            "-map", "0:v:0",
            "-map", "0:a?"
        ])

        arguments.append(contentsOf: ffmpegVideoCodecArguments(for: settings))

        switch settings.videoAudioMode {
        case .copy:
            arguments.append(contentsOf: ["-c:a", "copy"])
        case .aac192:
            arguments.append(contentsOf: ["-c:a", "aac", "-b:a", "192k"])
        case .aac320:
            arguments.append(contentsOf: ["-c:a", "aac", "-b:a", "320k"])
        }

        if settings.ffmpegThreads > 0 {
            arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
        }

        // Write to a unique temp sibling, then atomically replace the final
        // output on success. A cancelled or failed encode must never leave a
        // truncated file at the user-visible output path.
        let tempOutput = temporaryOutputURL(beside: output)
        arguments.append(tempOutput.path)
        let inputDuration = try? await FFmpegProbe.mediaDuration(
            ffmpegURL: ffmpegURL,
            input: input,
            processRegistry: processRegistry
        )

        return try await runInstallingTemp(temp: tempOutput, output: output) {
            try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: arguments,
                processRegistry: processRegistry
            ) { chunk in
                guard let progress = FFmpegProgressSnapshot.parse(
                    from: chunk,
                    duration: inputDuration
                ) else {
                    return
                }
                progressHandler?(progress)
            }
        }
    }

    private func encodeSplitMultichannel(
        input: URL,
        output: URL,
        settings: EncodingSettingsSnapshot,
        channelCount: Int,
        inputDuration: TimeInterval?,
        progressHandler: (@Sendable (FFmpegProgressSnapshot) -> Void)?
    ) async throws -> String {
        let groups = ffmpegChannelGroups(for: channelCount, settings: settings)
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
        for (splitIndex, pair) in zip(groups.indices, zip(groups, outputURLs)) {
            let (group, outputURL) = pair
            var arguments = [
                "-hide_banner",
                "-nostdin",
                settings.overwriteExisting ? "-y" : "-n",
                "-i", input.path,
                "-vn",
                "-filter:a", ffmpegPanFilter(for: group)
            ]
            arguments.append(contentsOf: try ffmpegCodecArguments(for: settings))
            if settings.ffmpegThreads > 0 {
                arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
            }

            // Write to a unique temp sibling, then atomically replace the final
            // output on success. A cancelled or failed encode must never leave a
            // truncated file at the user-visible output path.
            let tempOutput = temporaryOutputURL(beside: outputURL)
            arguments.append(tempOutput.path)

            let output = try await runInstallingTemp(temp: tempOutput, output: outputURL) {
                try await ProcessRunner.run(
                    executableURL: ffmpegURL,
                    arguments: arguments,
                    processRegistry: processRegistry
                ) { chunk in
                    guard let progress = FFmpegProgressSnapshot.parse(
                        from: chunk,
                        duration: inputDuration
                    ) else {
                        return
                    }
                    progressHandler?(
                        progress.aggregatingSplit(index: splitIndex, total: groups.count)
                    )
                }
            }
            progressHandler?(
                FFmpegProgressSnapshot(fps: nil, speed: nil)
                    .aggregatingSplit(index: splitIndex, total: groups.count, completed: true)
            )
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

    private func splitOutputURL(baseURL: URL, startChannel: Int, endChannel: Int) -> URL {
        let directory = baseURL.deletingLastPathComponent()
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension
        return directory.appendingPathComponent(
            "\(baseName)_ch\(startChannel)-\(endChannel).\(fileExtension)",
            isDirectory: false
        )
    }

    /// A unique temp-file URL beside `output` that preserves the output's
    /// extension. ffmpeg writes here; on success the temp replaces `output`
    /// atomically so a cancelled or failed encode leaves no truncated output.
    private func temporaryOutputURL(beside output: URL) -> URL {
        let directory = output.deletingLastPathComponent()
        let fileExtension = output.pathExtension
        let stem = ".gphilcoder-encoding-\(UUID().uuidString)"
        let name = fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Runs an encode that writes to `temp`, then installs the temp at `output`
    /// on success. On any throw (including `CancellationError`) the temp is
    /// removed and `output` is left untouched. Mirrors the temp+replace
    /// discipline already used by the sync and copy planners.
    private func runInstallingTemp(
        temp: URL,
        output: URL,
        _ work: () async throws -> String
    ) async throws -> String {
        let fileManager = FileManager.default
        do {
            let result = try await work()
            if fileManager.fileExists(atPath: temp.path) {
                _ = try fileManager.replaceItemAt(
                    output,
                    withItemAt: temp,
                    backupItemName: nil,
                    options: []
                )
            } else {
                // ffmpeg reported success but produced no output file (e.g.
                // an empty/passthrough case). Treat as a write failure so the
                // job is flagged instead of silently succeeding.
                throw FFmpegToolError.processFailed(status: 0, output: result)
            }
            return result
        } catch {
            if fileManager.fileExists(atPath: temp.path) {
                try? fileManager.removeItem(at: temp)
            }
            throw error
        }
    }
}

enum FFmpegProbe {
    /// Runs `ffmpeg -i <input>` (which exits non-zero but prints stream info
    /// to stderr) and parses the audio channel count via the Core helper.
    static func audioChannelCount(
        ffmpegURL: URL,
        input: URL,
        processRegistry: ProcessRegistry? = nil
    ) async throws -> Int? {
        let output: String
        do {
            output = try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: ["-hide_banner", "-i", input.path],
                processRegistry: processRegistry
            )
        } catch FFmpegToolError.processFailed(_, let probeOutput) {
            output = probeOutput
        }

        return parseAudioChannelCount(from: output)
    }

    static func mediaDuration(
        ffmpegURL: URL,
        input: URL,
        processRegistry: ProcessRegistry? = nil
    ) async throws -> TimeInterval? {
        let output: String
        do {
            output = try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: ["-hide_banner", "-i", input.path],
                processRegistry: processRegistry
            )
        } catch FFmpegToolError.processFailed(_, let probeOutput) {
            output = probeOutput
        }

        return FFmpegProgressSnapshot.parseDuration(from: output)
    }
}

final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var shouldTerminateNewProcesses = false

    func insert(_ process: Process) {
        lock.lock()
        let shouldTerminate = shouldTerminateNewProcesses
        if !shouldTerminate {
            processes[ObjectIdentifier(process)] = process
        }
        lock.unlock()

        if shouldTerminate {
            process.terminate()
        }
    }

    func remove(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        shouldTerminateNewProcesses = false
        processes.removeAll()
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        shouldTerminateNewProcesses = true
        let activeProcesses = Array(processes.values)
        lock.unlock()

        for process in activeProcesses {
            process.terminate()
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
    static func run(
        executableURL: URL,
        arguments: [String],
        processRegistry: ProcessRegistry? = nil,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
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
                    let data = handle.availableData
                    outputBuffer.append(data)
                    if let outputHandler,
                        let text = String(data: data, encoding: .utf8),
                        !text.isEmpty
                    {
                        outputHandler(text)
                    }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    errorBuffer.append(data)
                    if let outputHandler,
                        let text = String(data: data, encoding: .utf8),
                        !text.isEmpty
                    {
                        outputHandler(text)
                    }
                }

                process.standardOutput = outputPipe
                process.standardError = errorPipe
                processBox.set(process)

                do {
                    try process.run()
                    processRegistry?.insert(process)
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    throw FFmpegToolError.couldNotStart(error.localizedDescription)
                }
                defer {
                    processRegistry?.remove(process)
                }

                process.waitUntilExit()

                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                outputBuffer.append(remainingOutput)
                if let outputHandler,
                    let text = String(data: remainingOutput, encoding: .utf8),
                    !text.isEmpty
                {
                    outputHandler(text)
                }

                let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
                errorBuffer.append(remainingError)
                if let outputHandler,
                    let text = String(data: remainingError, encoding: .utf8),
                    !text.isEmpty
                {
                    outputHandler(text)
                }

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
