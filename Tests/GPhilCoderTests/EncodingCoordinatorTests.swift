import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

@MainActor
final class EncodingCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearViewModelDefaultsForTests()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearViewModelDefaultsForTests()
        try super.tearDownWithError()
    }

    func testStartEncodingProducesOutputFile() async throws {
        let model = try makeEncodingModel(outputFormat: .flac)
        let source = try writeWAV(
            named: "tone.wav",
            in: try makeTemporaryDirectory(),
            seconds: 0.25
        )
        let outputDirectory = try makeTemporaryDirectory()

        _ = model.addFileURLs([source])
        model.exportFolder = outputDirectory

        model.startEncoding()

        let completed = await waitUntil { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.succeeded])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent("tone.flac").path
            )
        )
    }

    func testExistingOutputSkipsSameFormatEncodedSuffix() async throws {
        let model = try makeEncodingModel(outputFormat: .flac)
        let sourceDirectory = try makeTemporaryDirectory()
        let source = try writeWAV(named: "same.flac", in: sourceDirectory, seconds: 0.25)
        let outputDirectory = try makeTemporaryDirectory()
        let existingOutput = outputDirectory.appendingPathComponent("same-encoded.flac")
        try Data("existing".utf8).write(to: existingOutput)

        _ = model.addFileURLs([source])
        model.exportFolder = outputDirectory

        model.startEncoding()

        let completed = await waitUntil { !model.isEncoding && !model.jobs.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.map(\.state), [.skipped])
        XCTAssertEqual(model.jobs.first?.outputURL.lastPathComponent, "same-encoded.flac")
        XCTAssertEqual(try Data(contentsOf: existingOutput), Data("existing".utf8))
    }

    func testCancelEncodingDoesNotReplaceExistingOutput() async throws {
        let model = try makeEncodingModel(outputFormat: .flac)
        let source = try writeWAV(
            named: "long.wav",
            in: try makeTemporaryDirectory(),
            seconds: 120
        )
        let outputDirectory = try makeTemporaryDirectory()
        let output = outputDirectory.appendingPathComponent("long.flac")
        let sentinel = Data("keep-existing-output".utf8)
        try sentinel.write(to: output)

        _ = model.addFileURLs([source])
        model.exportFolder = outputDirectory
        model.overwriteExisting = true

        model.startEncoding()

        let reachedRunning = await waitUntil(timeout: 2) {
            model.jobs.contains { $0.state == .running }
        }
        guard reachedRunning else {
            if model.jobs.first?.state == .succeeded {
                throw XCTSkip("Encoding completed before cancellation could be observed.")
            }
            XCTFail("Encoding never reached a running state.")
            return
        }

        model.cancelEncoding()

        let cancelled = await waitUntil(timeout: 10) { !model.isEncoding }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.jobs.first?.state, .cancelled)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    private func makeEncodingModel(outputFormat: AudioOutputFormat) throws -> EncoderViewModel {
        let model = EncoderViewModel()
        model.completionNotificationsEnabled = false
        model.confirmBeforeEncoding = false
        model.encodingWorkflow = .audio
        model.ffmpegSourcePreference = .system
        model.refreshFFmpeg()
        guard model.encodingFFmpegURL != nil else {
            throw XCTSkip("System ffmpeg is not available.")
        }
        model.outputMode = .exportFolder
        model.preserveSubfolders = false
        model.overwriteExisting = false
        model.outputFormat = outputFormat
        model.parallelJobs = 1
        model.ffmpegThreads = 1
        return model
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeWAV(
        named name: String,
        in directory: URL,
        seconds: Double,
        sampleRate: Int = 44_100
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let sampleCount = Int(Double(sampleRate) * seconds)
        let bytesPerSample = 2
        let dataByteCount = sampleCount * bytesPerSample

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataByteCount).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(sampleRate * bytesPerSample).littleEndianData)
        data.append(UInt16(bytesPerSample).littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataByteCount).littleEndianData)

        for index in 0..<sampleCount {
            let phase = Double(index) * 440 * 2 * .pi / Double(sampleRate)
            let sample = Int16((sin(phase) * 16_000).rounded())
            data.append(sample.littleEndianData)
        }

        try data.write(to: url)
        return url
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
