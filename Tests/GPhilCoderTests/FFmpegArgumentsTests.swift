import Foundation
import XCTest
@testable import GPhilCoderCore

final class FFmpegArgumentsTests: XCTestCase {
    // MARK: - Codec arguments

    func testCodecArgumentsMP3VBR() throws {
        let settings = makeSettings(outputFormat: .mp3, mp3Mode: .vbr, vbrQuality: 4)
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, ["-codec:a", "libmp3lame", "-q:a", "4"])
    }

    func testCodecArgumentsMP3CBR() throws {
        let settings = makeSettings(outputFormat: .mp3, mp3Mode: .cbr, cbrBitrateKbps: 320)
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, ["-codec:a", "libmp3lame", "-b:a", "320k"])
    }

    func testCodecArgumentsMP3ABR() throws {
        let settings = makeSettings(outputFormat: .mp3, mp3Mode: .abr, abrBitrateKbps: 190)
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, ["-codec:a", "libmp3lame", "-abr", "1", "-b:a", "190k"])
    }

    func testCodecArgumentsOpusCBR() throws {
        let settings = makeSettings(
            outputFormat: .opus, opusRateMode: .cbr, opusBitrateKbps: 128
        )
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, [
            "-codec:a", "libopus",
            "-b:a", "128k",
            "-vbr", "off",
            "-compression_level", "10"
        ])
    }

    func testCodecArgumentsFLACCompressionLevel() throws {
        let settings = makeSettings(outputFormat: .flac, flacCompressionLevel: 8)
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, ["-codec:a", "flac", "-compression_level", "8"])
    }

    func testCodecArgumentsWavPack() throws {
        let settings = makeSettings(outputFormat: .wavpack)
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, ["-codec:a", "wavpack"])
    }

    func testCodecArgumentsOggBitrateRequiresLibVorbis() throws {
        let settings = makeSettings(
            useLibVorbis: false, outputFormat: .ogg, oggMode: .bitrate, oggBitrateKbps: 192
        )
        XCTAssertThrowsError(try ffmpegCodecArguments(for: settings)) { error in
            XCTAssertEqual(error as? FFmpegToolError, .unsupportedOggBitrate)
        }
    }

    func testCodecArgumentsOggBitrateWithLibVorbis() throws {
        let settings = makeSettings(
            useLibVorbis: true, outputFormat: .ogg, oggMode: .bitrate, oggBitrateKbps: 192
        )
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, [
            "-codec:a", "libvorbis",
            "-ac", "2",
            "-b:a", "192k",
            "-strict", "-2"
        ])
    }

    func testCodecArgumentsOggQualityWithoutLibVorbis() throws {
        let settings = makeSettings(
            useLibVorbis: false, outputFormat: .ogg, oggMode: .quality, oggQuality: 5
        )
        let args = try ffmpegCodecArguments(for: settings)
        XCTAssertEqual(args, [
            "-codec:a", "vorbis",
            "-ac", "2",
            "-qscale:a", "5",
            "-strict", "-2"
        ])
    }

    // MARK: - Video codec arguments

    func testVideoCodecArgumentsIncludesBitrateAndHEVC() throws {
        let settings = makeSettings(encodingWorkflow: .video)
        let args = ffmpegVideoCodecArguments(for: settings)

        XCTAssertNotNil(args.firstIndex(of: "-c:v"))
        XCTAssertNotNil(args.firstIndex(of: "hevc_videotoolbox"))
        XCTAssertNotNil(args.firstIndex(of: "-tag:v"))
        XCTAssertEqual(args[args.firstIndex(of: "-tag:v")! + 1], "hvc1")
    }

    func testVideoScaleFilterOmitsWhenNoCap() {
        XCTAssertNil(ffmpegVideoScaleFilter(for: .source))
    }

    func testVideoScaleFilterEmitsScaleFor1080p() {
        let filter = ffmpegVideoScaleFilter(for: .max1080p)
        XCTAssertNotNil(filter)
        XCTAssertTrue(filter?.contains("force_original_aspect_ratio=decrease") == true)
    }

    // MARK: - Multichannel splitting

    func testShouldSplitFalseWhenDisabled() {
        let settings = makeSettings(outputFormat: .flac, splitOversizedMultichannel: false)
        XCTAssertFalse(ffmpegShouldSplitMultichannel(16, settings: settings))
    }

    func testShouldSplitFLACAboveEightChannels() {
        let settings = makeSettings(outputFormat: .flac, splitOversizedMultichannel: true)
        XCTAssertTrue(ffmpegShouldSplitMultichannel(9, settings: settings))
        XCTAssertFalse(ffmpegShouldSplitMultichannel(8, settings: settings))
    }

    func testShouldSplitWavPackAboveEighteenChannels() {
        let settings = makeSettings(outputFormat: .wavpack, splitOversizedMultichannel: true)
        XCTAssertTrue(ffmpegShouldSplitMultichannel(19, settings: settings))
        XCTAssertFalse(ffmpegShouldSplitMultichannel(18, settings: settings))
    }

    func testShouldSplitNeverForLossyFormats() {
        let settings = makeSettings(outputFormat: .mp3, splitOversizedMultichannel: true)
        XCTAssertFalse(ffmpegShouldSplitMultichannel(64, settings: settings))
    }

    func testChannelGroupsFLACSplitsAtEight() {
        let settings = makeSettings(outputFormat: .flac, splitOversizedMultichannel: true)
        let groups = ffmpegChannelGroups(for: 20, settings: settings)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].start...groups[0].end, 1...8)
        XCTAssertEqual(groups[1].start...groups[1].end, 9...16)
        XCTAssertEqual(groups[2].start...groups[2].end, 17...20)
    }

    func testChannelGroupsWavPackMergesFinalTwoGroups() {
        // 18 channels with a group size of 10 would naively be [1-10, 11-18];
        // the merge rule collapses them into one group (1-18) since the
        // combined count fits within the 18 standard named speakers.
        let settings = makeSettings(outputFormat: .wavpack, splitOversizedMultichannel: true)
        let groups = ffmpegChannelGroups(for: 18, settings: settings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].start...groups[0].end, 1...18)
    }

    func testChannelGroupsWavPackDoesNotMergeWhenTooLarge() {
        // 25 channels → [1-10, 11-20, 21-25]. 21-25 merged with 11-20 would be
        // 15 channels (within 18), so the last two collapse to 11-25.
        let settings = makeSettings(outputFormat: .wavpack, splitOversizedMultichannel: true)
        let groups = ffmpegChannelGroups(for: 25, settings: settings)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].start...groups[0].end, 1...10)
        XCTAssertEqual(groups[1].start...groups[1].end, 11...25)
    }

    // MARK: - Pan filter

    func testPanFilterMonoGroup() {
        let filter = ffmpegPanFilter(for: (start: 1, end: 1))
        XCTAssertEqual(filter, "pan=mono|c0=c0")
    }

    func testPanFilterStereoGroupUsesFLFR() {
        let filter = ffmpegPanFilter(for: (start: 1, end: 2))
        XCTAssertEqual(filter, "pan=FL+FR|FL=c0|FR=c1")
    }

    func testPanFilterFiveOneGroup() {
        let filter = ffmpegPanFilter(for: (start: 3, end: 8))
        XCTAssertEqual(filter, "pan=FL+FR+FC+LFE+BL+BR|FL=c2|FR=c3|FC=c4|LFE=c5|BL=c6|BR=c7")
    }

    // MARK: - Channel-count parsing

    func testParseExplicitChannelsCount() {
        let output = "Stream #0:0: Audio: flac, 48000 Hz, 6 channels, s32 (24 bit)"
        XCTAssertEqual(parseAudioChannelCount(from: output), 6)
    }

    func testParseCompactChannelsCount() {
        // The compact form matches only at end-of-line or with trailing
        // whitespace; here it terminates the line.
        let output = "Stream #0:1: Audio: aac, 48000 Hz, 2ch"
        XCTAssertEqual(parseAudioChannelCount(from: output), 2)
    }

    func testParseLayoutFieldStereo() {
        let output = "Stream #0:0: Audio: mp3, 44100 Hz, stereo, fltp, 128 kb/s"
        XCTAssertEqual(parseAudioChannelCount(from: output), 2)
    }

    func testParseLayoutFieldFivePointOne() {
        let output = "Stream #0:0: Audio: ac3, 48000 Hz, 5.1(side), fltp, 448 kb/s"
        XCTAssertEqual(parseAudioChannelCount(from: output), 6)
    }

    func testParseLayoutFieldSevenPointOne() {
        let output = "Stream #0:0: Audio: dts, 48000 Hz, 7.1, fltp, 1536 kb/s"
        XCTAssertEqual(parseAudioChannelCount(from: output), 8)
    }

    func testParseReturnsNilWhenNoAudioLine() {
        let output = "no audio streams here"
        XCTAssertNil(parseAudioChannelCount(from: output))
    }

    // MARK: - Progress snapshot

    func testProgressSnapshotParsesFpsAndSpeed() {
        let snapshot = FFmpegProgressSnapshot.parse(
            from: "frame=  100 fps= 60.0 q=0.0 size=    1024kB time=00:00:02.00 bitrate=4194.3kbits/s speed=2x\r"
        )
        XCTAssertEqual(snapshot?.fps, "60.0")
        XCTAssertEqual(snapshot?.speed, "2x")
    }

    func testProgressSnapshotParsesFractionCompletedWhenDurationIsKnown() throws {
        let snapshot = FFmpegProgressSnapshot.parse(
            from: "frame=  100 fps= 60.0 q=0.0 size=    1024kB time=00:00:02.00 bitrate=4194.3kbits/s speed=2x\r",
            duration: 8
        )
        let fractionCompleted = try XCTUnwrap(snapshot?.fractionCompleted)
        XCTAssertEqual(fractionCompleted, 0.25, accuracy: 0.001)
    }

    func testProgressSnapshotParsesEstimatedTimeRemaining() throws {
        let snapshot = FFmpegProgressSnapshot.parse(
            from: "frame=  100 fps= 60.0 q=0.0 size=    1024kB time=00:00:02.00 bitrate=4194.3kbits/s speed=2x\r",
            duration: 8
        )
        XCTAssertEqual(try XCTUnwrap(snapshot?.estimatedSecondsRemaining), 3, accuracy: 0.001)
    }

    func testProgressSnapshotClampsFractionCompleted() {
        let snapshot = FFmpegProgressSnapshot.parse(
            from: "frame=  100 fps= 60.0 q=0.0 size=    1024kB time=00:00:12.00 bitrate=4194.3kbits/s speed=2x\r",
            duration: 8
        )
        XCTAssertEqual(snapshot?.fractionCompleted, 1)
    }

    func testProgressSnapshotParsesDuration() throws {
        let duration = FFmpegProgressSnapshot.parseDuration(
            from: "Duration: 00:01:02.50, start: 0.000000, bitrate: 1424 kb/s"
        )
        XCTAssertEqual(try XCTUnwrap(duration), 62.5, accuracy: 0.001)
    }

    func testProgressSnapshotAggregatesSplitFraction() throws {
        let snapshot = FFmpegProgressSnapshot(
            fps: "12.0",
            speed: "1.0x",
            fractionCompleted: 0.5,
            estimatedSecondsRemaining: 12
        )
            .aggregatingSplit(index: 1, total: 4)

        XCTAssertEqual(try XCTUnwrap(snapshot.fractionCompleted), 0.375, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimatedSecondsRemaining, 12)
        XCTAssertEqual(snapshot.fps, "12.0")
        XCTAssertEqual(snapshot.speed, "1.0x")
    }

    func testProgressSnapshotAggregatesCompletedSplit() throws {
        let snapshot = FFmpegProgressSnapshot(fps: nil, speed: nil)
            .aggregatingSplit(index: 2, total: 4, completed: true)

        XCTAssertEqual(try XCTUnwrap(snapshot.fractionCompleted), 0.75, accuracy: 0.001)
    }

    func testProgressSnapshotReturnsNilWhenNoProgressLine() {
        XCTAssertNil(FFmpegProgressSnapshot.parse(from: "Press [q] to quit"))
    }

    func testProgressSnapshotMessageFormatsBoth() {
        let snapshot = FFmpegProgressSnapshot(fps: "59.9", speed: "1.5x")
        XCTAssertEqual(snapshot.message, "Encoding... 59.9 fps, 1.5x realtime")
    }

    func testProgressSnapshotMessageEmptyWhenNoData() {
        let snapshot = FFmpegProgressSnapshot(fps: nil, speed: nil)
        XCTAssertEqual(snapshot.message, "Encoding...")
    }

    // MARK: - Fixtures

    private func makeSettings(
        ffmpegURL: URL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        useLibVorbis: Bool = true,
        encodingWorkflow: EncodingWorkflow = .audio,
        outputFormat: AudioOutputFormat = .mp3,
        videoOutputContainer: VideoOutputContainer = .mp4,
        hevcPreset: HEVCVideoPreset = .balanced1080p,
        customVideoBitrateKbps: Int = 8000,
        videoScaleMode: VideoScaleMode = .source,
        videoAudioMode: VideoAudioMode = .copy,
        videoHardwareDecodeMode: VideoHardwareDecodeMode = .off,
        mp3Mode: MP3EncodingMode = .vbr,
        vbrQuality: Int = 2,
        cbrBitrateKbps: Int = 192,
        abrBitrateKbps: Int = 190,
        oggMode: OggEncodingOptions.Mode = .quality,
        oggQuality: Int = 3,
        oggBitrateKbps: Int = 128,
        opusRateMode: OpusEncodingOptions.RateMode = .vbr,
        opusBitrateKbps: Int = 96,
        flacCompressionLevel: Int = 5,
        splitOversizedMultichannel: Bool = false,
        ffmpegThreads: Int = 0,
        overwriteExisting: Bool = false,
        parallelJobs: Int = 1
    ) -> EncodingSettingsSnapshot {
        EncodingSettingsSnapshot(
            ffmpegURL: ffmpegURL,
            useLibVorbis: useLibVorbis,
            encodingWorkflow: encodingWorkflow,
            outputFormat: outputFormat,
            videoOutputContainer: videoOutputContainer,
            hevcPreset: hevcPreset,
            customVideoBitrateKbps: customVideoBitrateKbps,
            videoScaleMode: videoScaleMode,
            videoAudioMode: videoAudioMode,
            videoHardwareDecodeMode: videoHardwareDecodeMode,
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
            ffmpegThreads: ffmpegThreads,
            overwriteExisting: overwriteExisting,
            parallelJobs: parallelJobs
        )
    }
}
