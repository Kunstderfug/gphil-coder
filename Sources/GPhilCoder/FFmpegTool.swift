import Foundation

enum FFmpegToolError: LocalizedError {
    case notFound
    case unsupportedOggBitrate
    case outputWouldOverwriteInput
    case processFailed(status: Int32, output: String)
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "FFmpeg was not found. Install it with Homebrew or place ffmpeg in /opt/homebrew/bin or /usr/local/bin."
        case .unsupportedOggBitrate:
            return "Ogg bitrate mode requires FFmpeg with the libvorbis encoder. Use Ogg quality mode or install an FFmpeg build with libvorbis."
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
    static func locate() -> URL? {
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

        if FileManager.default.fileExists(atPath: output.path), !settings.overwriteExisting {
            throw EncodeSkipError.outputExists
        }

        var arguments = [
            "-hide_banner",
            "-nostdin",
            settings.overwriteExisting ? "-y" : "-n",
            "-i", input.path,
            "-vn"
        ]

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
        }

        if settings.ffmpegThreads > 0 {
            arguments.append(contentsOf: ["-threads", "\(settings.ffmpegThreads)"])
        }

        arguments.append(output.path)

        return try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
    }
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
