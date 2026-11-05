import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

@MainActor
final class AudioExtractionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var savedDefaults: [String: Any] = [:]
    private let defaultsKeys = [
        "extractAudioFromVideo", "copyOriginalAudio", "encodingWorkflow", "selectedInputExtensions",
        "selectedVideoInputExtensions", "completionNotificationsEnabled",
        "confirmBeforeEncoding", "ffmpegSourcePreference", "outputMode", "exportFolderPath",
        "preserveSubfolders", "overwriteExisting", "outputFormat", "parallelJobs",
        "ffmpegThreads", "splitOversizedMultichannel"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        for key in defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        for key in defaultsKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        try super.tearDownWithError()
    }

    func testExtractionAcceptsVideoInputsAndUsesVideoFilters() throws {
        let model = EncoderViewModel()
        model.encodingWorkflow = .audio
        XCTAssertFalse(model.extractAudioFromVideo)
        model.extractAudioFromVideo = true
        model.selectAllInputFormats()
        XCTAssertEqual(model.inputWorkflow, .video)
        XCTAssertEqual(model.encodingWorkflow, .audio)

        let directory = try makeTemporaryDirectory()
        let sources = ["clip.mp4", "camera.MOV", "movie.m4v", "song.wav"].map {
            directory.appendingPathComponent($0)
        }
        for source in sources { try Data().write(to: source) }
        let result = model.addFileURLs(sources)
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.unsupported, 1)
        XCTAssertEqual(model.activeInputs.count, 3)

        model.deselectAllInputFormats()
        model.setInputFormat(InputVideoFormat.mov, enabled: true)
        XCTAssertEqual(model.activeInputs.map(\.name), ["camera.MOV"])

        model.extractAudioFromVideo = false
        XCTAssertEqual(model.inputWorkflow, .audio)
        XCTAssertTrue(model.activeInputs.isEmpty)
        XCTAssertEqual(model.inputs.count, 3)
        model.selectAllInputFormats()
        XCTAssertEqual(model.addFileURLs([sources[3]]).added, 1)
        XCTAssertEqual(model.activeInputs.map(\.name), ["song.wav"])

        model.extractAudioFromVideo = true
        XCTAssertEqual(model.activeInputs.map(\.name), ["camera.MOV"])
        model.encodingWorkflow = .video
        XCTAssertEqual(model.inputWorkflow, .video)
    }

    func testExtractionPreferenceReloadsAndQueueSettingsRoundTrip() throws {
        var model: EncoderViewModel? = EncoderViewModel()
        model?.encodingWorkflow = .audio
        model?.extractAudioFromVideo = true
        model?.copyOriginalAudio = false
        model = nil
        let reloaded = EncoderViewModel()
        XCTAssertTrue(reloaded.extractAudioFromVideo)
        XCTAssertFalse(reloaded.copyOriginalAudio)

        var settings = QueueSettings()
        settings.encodingWorkflow = "audio"
        settings.extractAudioFromVideo = true
        settings.copyOriginalAudio = false
        settings.outputFormat = "flac"
        settings.selectedVideoInputExtensions = ["mp4", "mov"]
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(QueueSettings.self, from: data)
        XCTAssertEqual(restored.extractAudioFromVideo, true)
        XCTAssertEqual(restored.copyOriginalAudio, false)
        XCTAssertEqual(restored.encodingWorkflow, "audio")
        XCTAssertEqual(restored.outputFormat, "flac")
        XCTAssertEqual(restored.selectedVideoInputExtensions, ["mp4", "mov"])
        let legacy = try JSONDecoder().decode(QueueSettings.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.extractAudioFromVideo)
        XCTAssertNil(legacy.copyOriginalAudio)
    }

    func testExtractingVideoProducesAudioOnlyFLACAndPreservesSource() async throws {
        let model = try makeEncodingModel()
        model.copyOriginalAudio = false
        let source = try makeVideo(withAudio: true)
        let original = try Data(contentsOf: source)
        let outputDirectory = try makeTemporaryDirectory()
        model.exportFolder = outputDirectory
        XCTAssertEqual(model.addFileURLs([source]).added, 1)

        model.startEncoding()
        let completed = await waitUntil(timeout: 10) { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.succeeded], model.jobs.first?.message ?? "")
        let output = outputDirectory.appendingPathComponent("clip.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let probe = try run(try executable(named: "ffprobe"), [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name",
            "-of", "json", output.path
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?["codec_type"] as? String, "audio")
        XCTAssertEqual(streams.first?["codec_name"] as? String, "flac")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDefaultExtractionCopiesOriginalAACPacketsWithoutEncoding() async throws {
        let model = try makeEncodingModel()
        XCTAssertTrue(model.copyOriginalAudio)
        let source = try makeVideo(withAudio: true)
        let original = try Data(contentsOf: source)
        let outputDirectory = try makeTemporaryDirectory()
        model.exportFolder = outputDirectory
        _ = model.addFileURLs([source])

        model.startEncoding()
        let completed = await waitUntil(timeout: 10) { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.succeeded], model.jobs.first?.message ?? "")
        let output = outputDirectory.appendingPathComponent("clip.m4a")
        XCTAssertEqual(model.jobs.first?.outputURL, output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let probe = try run(try executable(named: "ffprobe"), [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", output.path
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?["codec_type"] as? String, "audio")
        XCTAssertEqual(streams.first?["codec_name"] as? String, "aac")

        let ffmpeg = try executable(named: "ffmpeg")
        func packetHash(_ input: URL) throws -> String {
            try run(ffmpeg, [
                "-v", "error", "-i", input.path, "-map", "0:a:0", "-c:a", "copy",
                "-f", "hash", "-hash", "sha256", "-"
            ])
        }
        XCTAssertEqual(try packetHash(source), try packetHash(output))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSilentVideoFailsWithoutLeavingOutput() async throws {
        let model = try makeEncodingModel()
        let source = try makeVideo(withAudio: false)
        let outputDirectory = try makeTemporaryDirectory()
        model.exportFolder = outputDirectory
        _ = model.addFileURLs([source])

        model.startEncoding()
        let completed = await waitUntil(timeout: 10) { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.failed])
        XCTAssertFalse(model.jobs.first?.message.isEmpty ?? true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testOriginalExtractionKeepsFirstALACTrack() async throws {
        let model = try makeEncodingModel()
        let source = try makeTemporaryDirectory().appendingPathComponent("multitrack.mov")
        _ = try run(try executable(named: "ffmpeg"), [
            "-v", "error", "-f", "lavfi", "-i", "color=size=32x32:rate=10",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=44100",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-t", "0.25",
            "-c:v", "mpeg4", "-c:a", "alac", source.path
        ])
        let outputDirectory = try makeTemporaryDirectory()
        model.exportFolder = outputDirectory
        _ = model.addFileURLs([source])
        model.startEncoding()
        let completed = await waitUntil(timeout: 10) { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.succeeded], model.jobs.first?.message ?? "")
        let output = outputDirectory.appendingPathComponent("multitrack.m4a")
        let probe = try run(try executable(named: "ffprobe"), [
            "-v", "error", "-show_entries", "stream=codec_name", "-of", "json", output.path
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?["codec_name"] as? String, "alac")
        let ffmpeg = try executable(named: "ffmpeg")
        let hashArguments = ["-map", "0:a:0", "-c:a", "copy", "-f", "hash", "-hash", "sha256", "-"]
        XCTAssertEqual(
            try run(ffmpeg, ["-v", "error", "-i", source.path] + hashArguments),
            try run(ffmpeg, ["-v", "error", "-i", output.path] + hashArguments)
        )
    }

    func testOriginalExtractionBatchIsolatesSilentFailureAndSkipsExistingOutput() async throws {
        let model = try makeEncodingModel()
        let directory = try makeTemporaryDirectory()
        let valid = directory.appendingPathComponent("a-valid.mp4")
        let silent = directory.appendingPathComponent("b-silent.mp4")
        let skipped = directory.appendingPathComponent("c-existing.mp4")
        try FileManager.default.copyItem(at: makeVideo(withAudio: true), to: valid)
        try FileManager.default.copyItem(at: makeVideo(withAudio: false), to: silent)
        try FileManager.default.copyItem(at: valid, to: skipped)
        let outputDirectory = try makeTemporaryDirectory()
        let sentinel = Data("preserve existing original audio".utf8)
        let existing = outputDirectory.appendingPathComponent("c-existing.m4a")
        try sentinel.write(to: existing)
        model.exportFolder = outputDirectory
        _ = model.addFileURLs([valid, silent, skipped])

        model.startEncoding()
        let completed = await waitUntil(timeout: 10) { !model.isEncoding && model.jobs.count == 3 }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.succeeded, .failed, .skipped])
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted(),
            ["a-valid.m4a", "c-existing.m4a"]
        )
    }

    private func makeEncodingModel() throws -> EncoderViewModel {
        _ = try executable(named: "ffmpeg")
        let model = EncoderViewModel()
        model.completionNotificationsEnabled = false
        model.confirmBeforeEncoding = false
        model.encodingWorkflow = .audio
        model.extractAudioFromVideo = true
        model.selectAllInputFormats()
        model.ffmpegSourcePreference = .system
        model.refreshFFmpeg()
        XCTAssertNotNil(model.encodingFFmpegURL)
        model.outputMode = .exportFolder
        model.preserveSubfolders = false
        model.overwriteExisting = false
        model.outputFormat = .flac
        model.splitOversizedMultichannel = false
        model.parallelJobs = 1
        model.ffmpegThreads = 1
        return model
    }

    private func makeVideo(withAudio: Bool) throws -> URL {
        let source = try makeTemporaryDirectory().appendingPathComponent("clip.mp4")
        var arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=size=32x32:rate=10"]
        if withAudio {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-c:a", "aac"]
        }
        arguments += ["-t", "0.25", "-c:v", "mpeg4", "-y", source.path]
        _ = try run(try executable(named: "ffmpeg"), arguments)
        return source
    }

    private func executable(named name: String) throws -> URL {
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" }
        guard let path = candidates.map({ $0 + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed.")
        }
        return URL(fileURLWithPath: path)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            XCTFail("Fixture tool failed: \(output)")
            throw NSError(domain: "AudioExtractionTests", code: Int(process.terminationStatus))
        }
        return output
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioExtractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
