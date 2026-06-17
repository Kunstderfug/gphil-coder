import Foundation
import XCTest
@testable import GPhilCoderCore

final class EncodingPresetTests: XCTestCase {
    // MARK: - Fixtures

    private func makeAudioPreset(id: UUID = UUID(), name: String = "Studio MP3") -> EncodingPreset {
        EncodingPreset(
            id: id,
            name: name,
            workflow: .audio,
            audio: AudioEncodingPresetSettings(
                outputFormat: .mp3,
                mp3Mode: .vbr,
                vbrQuality: 2,
                cbrBitrateKbps: 256,
                abrBitrateKbps: 220,
                oggMode: .quality,
                oggQuality: 6,
                oggBitrateKbps: 192,
                opusRateMode: .vbr,
                opusBitrateKbps: 128,
                flacCompressionLevel: 8,
                splitOversizedMultichannel: true
            )
        )
    }

    private func makeVideoPreset(id: UUID = UUID(), name: String = "4K Balanced") -> EncodingPreset {
        EncodingPreset(
            id: id,
            name: name,
            workflow: .video,
            video: VideoEncodingPresetSettings(
                outputContainer: .mp4,
                hevcPreset: .balanced4k,
                customBitrateKbps: 9_500,
                audioMode: .aac192,
                hardwareDecodeMode: .on
            )
        )
    }

    private func encoder() -> JSONEncoder {
        JSONEncoder()
    }

    private func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    // MARK: - Round-trip

    func testDocumentRoundTripsAudioAndVideoPresets() throws {
        let document = EncodingPresetDocument(presets: [makeAudioPreset(), makeVideoPreset()])

        let data = try encoder().encode(document)
        let restored = try decoder().decode(EncodingPresetDocument.self, from: data)

        XCTAssertEqual(restored.version, EncodingPresetDocument.currentVersion)
        XCTAssertEqual(restored.presets.count, 2)
        XCTAssertEqual(restored.presets, document.presets)
    }

    func testVideoPresetScaleModeDefaultsFromHEVCPresetWhenAbsent() throws {
        // scaleMode omitted at construction time falls back to the HEVC preset default.
        let preset = VideoEncodingPresetSettings(
            outputContainer: .mov,
            hevcPreset: .compact1080p,
            customBitrateKbps: 3_000,
            audioMode: .copy
        )
        XCTAssertEqual(preset.scaleMode, HEVCVideoPreset.compact1080p.defaultScaleMode)

        // Round-trips through Codable when the field is absent in JSON, recovering
        // the default rather than failing — this is the legacy-data path.
        let legacyJSON = """
            {"outputContainer":"mov","hevcPreset":"compact1080p","customBitrateKbps":3000,"audioMode":"copy"}
            """
        let restored = try decoder().decode(
            VideoEncodingPresetSettings.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(restored, preset)
    }

    // MARK: - decode(from:) outcome

    func testDecodeSucceedsForValidDocument() throws {
        let document = EncodingPresetDocument(presets: [makeAudioPreset(), makeVideoPreset()])
        let data = try encoder().encode(document)

        let result = EncodingPresetDocument.decode(from: data)
        guard case .success(let presets) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(presets, document.presets)
    }

    func testDecodeReportsVersionMismatchForNewerVersion() throws {
        // Build on-disk-shaped JSON with a newer version using a mirror of the
        // document's coding keys, so the version envelope is read before the
        // (valid) preset body is structurally decoded.
        let newer = VersionedDocument(version: 999, presets: [makeAudioPreset()])
        let data = try encoder().encode(newer)

        let result = EncodingPresetDocument.decode(from: data)
        XCTAssertEqual(
            result,
            .failure(.versionMismatch(found: 999, supported: EncodingPresetDocument.currentVersion))
        )
    }

    func testDecodeReportsCorruptionForUnparseableData() {
        let result = EncodingPresetDocument.decode(from: Data("{not json".utf8))
        guard case .failure(.corrupt) = result else {
            return XCTFail("Expected corrupt failure, got \(result)")
        }
    }

    // MARK: - normalize

    func testNormalizeKeepsMatchingWorkflowIDs() {
        let audio = makeAudioPreset()
        let video = makeVideoPreset()

        let normalized = EncodingPreset.normalize(
            selectedAudioID: audio.id,
            selectedVideoID: video.id,
            in: [audio, video]
        )

        XCTAssertEqual(normalized.audioID, audio.id)
        XCTAssertEqual(normalized.videoID, video.id)
    }

    func testNormalizeClearsWrongWorkflowSelection() {
        let audio = makeAudioPreset()
        let video = makeVideoPreset()

        // Audio selection points at the video preset and vice versa.
        let normalized = EncodingPreset.normalize(
            selectedAudioID: video.id,
            selectedVideoID: audio.id,
            in: [audio, video]
        )

        XCTAssertNil(normalized.audioID)
        XCTAssertNil(normalized.videoID)
    }

    func testNormalizeClearsDanglingIDs() {
        let audio = makeAudioPreset()

        let normalized = EncodingPreset.normalize(
            selectedAudioID: UUID(),  // does not exist
            selectedVideoID: UUID(),  // no video preset exists
            in: [audio]
        )

        XCTAssertNil(normalized.audioID)
        XCTAssertNil(normalized.videoID)
    }

    func testNormalizeKeepsNilSelections() {
        let audio = makeAudioPreset()

        let normalized = EncodingPreset.normalize(
            selectedAudioID: nil,
            selectedVideoID: nil,
            in: [audio]
        )

        XCTAssertNil(normalized.audioID)
        XCTAssertNil(normalized.videoID)
    }
}

/// Same coding shape as EncodingPresetDocument, but lets the test pin an
/// arbitrary version so the version envelope is observed by decode(from:).
private struct VersionedDocument: Codable {
    let version: Int
    let presets: [EncodingPreset]
}
