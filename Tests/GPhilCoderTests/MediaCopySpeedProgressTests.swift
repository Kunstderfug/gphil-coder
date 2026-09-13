import Foundation
import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class MediaCopySpeedProgressTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearMediaFileManagerDefaultsForTests()
        MediaCopyTransactionExecutor.resetByteProgressTestHooks()
    }

    override func tearDownWithError() throws {
        MediaCopyTransactionExecutor.resetByteProgressTestHooks()
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearMediaFileManagerDefaultsForTests()
        try super.tearDownWithError()
    }

    func testSamplerWindowSpeedMatchesSteadyRateAfterEarlierRamp() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(now: { clock.now })
        let startedAt = clock.now

        ingest(
            &sampler,
            copiedBytes: 0,
            startedAt: startedAt,
            clock: clock,
            advance: 0
        )
        for step in 1...5 {
            ingest(
                &sampler,
                copiedBytes: Int64(step) * 200_000,
                startedAt: startedAt,
                clock: clock,
                advance: 1
            )
        }
        for step in 1...10 {
            let reading = ingest(
                &sampler,
                copiedBytes: 1_000_000 + Int64(step) * 5_000_000,
                startedAt: startedAt,
                clock: clock,
                advance: 1
            )
            if step == 10 {
                XCTAssertEqual(try XCTUnwrap(reading.currentBytesPerSecond), 5_000_000, accuracy: 1)
                XCTAssertNotEqual(reading.currentBytesPerSecond, reading.averageBytesPerSecond)
            }
        }
    }

    func testSamplerBurstThenStallDecaysWindowWhileAverageRemains() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(now: { clock.now })
        let startedAt = clock.now

        ingest(&sampler, copiedBytes: 0, startedAt: startedAt, clock: clock, advance: 0)
        ingest(&sampler, copiedBytes: 20_000_000, startedAt: startedAt, clock: clock, advance: 1)
        XCTAssertEqual(
            try XCTUnwrap(
                ingest(&sampler, copiedBytes: 20_000_000, startedAt: startedAt, clock: clock, advance: 1)
                    .currentBytesPerSecond
            ),
            10_000_000,
            accuracy: 1
        )

        var latest = MediaCopySpeedReading(
            currentBytesPerSecond: nil,
            averageBytesPerSecond: nil,
            isStalled: false,
            byteFractionCompleted: 0
        )
        for _ in 0..<10 {
            latest = ingest(
                &sampler,
                copiedBytes: 20_000_000,
                startedAt: startedAt,
                clock: clock,
                advance: 1
            )
        }

        XCTAssertEqual(try XCTUnwrap(latest.currentBytesPerSecond), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(latest.averageBytesPerSecond), 20_000_000.0 / 12.0, accuracy: 1)
        XCTAssertGreaterThan(latest.averageBytesPerSecond ?? 0, 1_000_000)
    }

    func testSamplerDropsSamplesOlderThanWindow() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(windowDuration: 10, now: { clock.now })
        let startedAt = clock.now

        ingest(&sampler, copiedBytes: 0, startedAt: startedAt, clock: clock, advance: 0)
        ingest(&sampler, copiedBytes: 50_000_000, startedAt: startedAt, clock: clock, advance: 1)
        XCTAssertEqual(sampler.retainedSampleCount, 2)

        ingest(&sampler, copiedBytes: 50_500_000, startedAt: startedAt, clock: clock, advance: 1)
        ingest(&sampler, copiedBytes: 51_000_000, startedAt: startedAt, clock: clock, advance: 1)
        let countWithInWindowHistory = sampler.retainedSampleCount
        XCTAssertGreaterThan(countWithInWindowHistory, 2)

        let aged = ingest(
            &sampler,
            copiedBytes: 52_000_000,
            startedAt: startedAt,
            clock: clock,
            advance: 11
        )

        XCTAssertLessThan(sampler.retainedSampleCount, countWithInWindowHistory)
        XCTAssertEqual(sampler.retainedSampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(aged.currentBytesPerSecond), 1_000_000 / 11.0, accuracy: 1)
        XCTAssertLessThan(aged.currentBytesPerSecond ?? .greatestFiniteMagnitude, 2_000_000)

        let afterBurstAgesOut = ingest(
            &sampler,
            copiedBytes: 53_000_000,
            startedAt: startedAt,
            clock: clock,
            advance: 1
        )
        XCTAssertLessThanOrEqual(sampler.retainedSampleCount, 3)
        XCTAssertEqual(
            try XCTUnwrap(afterBurstAgesOut.currentBytesPerSecond),
            2_000_000 / 12.0,
            accuracy: 1
        )
        XCTAssertLessThan(
            afterBurstAgesOut.currentBytesPerSecond ?? .greatestFiniteMagnitude,
            2_000_000
        )
    }

    func testSamplerRaisesStalledDuringActiveTransferAndClearsWhenBytesResume() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(stallDuration: 3, now: { clock.now })
        let startedAt = clock.now

        ingest(
            &sampler,
            copiedBytes: 100_000,
            startedAt: startedAt,
            clock: clock,
            advance: 0,
            currentName: "large-one.wav"
        )
        let transferring = ingest(
            &sampler,
            copiedBytes: 500_000,
            startedAt: startedAt,
            clock: clock,
            advance: 1,
            currentName: "large-one.wav"
        )
        XCTAssertFalse(transferring.isStalled)
        let countAfterIncrease = sampler.retainedSampleCount

        clock.advance(3)
        let stalled = try XCTUnwrap(sampler.tick())
        XCTAssertTrue(stalled.isStalled)
        XCTAssertEqual(sampler.retainedSampleCount, countAfterIncrease)

        let resumed = ingest(
            &sampler,
            copiedBytes: 750_000,
            startedAt: startedAt,
            clock: clock,
            advance: 1,
            currentName: "large-one.wav"
        )
        XCTAssertFalse(resumed.isStalled)
    }

    func testSamplerDoesNotStallOnInterFileBookkeepingGap() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(stallDuration: 3, now: { clock.now })
        let startedAt = clock.now

        ingest(
            &sampler,
            copiedBytes: 100_000,
            startedAt: startedAt,
            clock: clock,
            advance: 0,
            currentName: "large-one.wav"
        )
        ingest(
            &sampler,
            copiedBytes: 2_000_000,
            startedAt: startedAt,
            clock: clock,
            advance: 1,
            currentName: "large-one.wav"
        )
        let bookkeeping = ingest(
            &sampler,
            copiedBytes: 2_000_000,
            startedAt: startedAt,
            clock: clock,
            advance: 3,
            currentName: "large-two.wav"
        )
        XCTAssertFalse(bookkeeping.isStalled)

        let nextFile = ingest(
            &sampler,
            copiedBytes: 2_100_000,
            startedAt: startedAt,
            clock: clock,
            advance: 1,
            currentName: "large-two.wav"
        )
        XCTAssertFalse(nextFile.isStalled)
    }

    func testSamplerDoesNotCountSkippedExistingAsThroughput() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        var sampler = MediaCopySpeedSampler(now: { clock.now })
        let startedAt = clock.now

        ingest(
            &sampler,
            copiedBytes: 0,
            startedAt: startedAt,
            clock: clock,
            advance: 0,
            skippedExisting: 0
        )
        let afterSkip = ingest(
            &sampler,
            copiedBytes: 0,
            startedAt: startedAt,
            clock: clock,
            advance: 1,
            completed: 1,
            skippedExisting: 1,
            currentName: "already-there.wav"
        )
        XCTAssertNil(afterSkip.currentBytesPerSecond)
        XCTAssertNil(afterSkip.averageBytesPerSecond)

        let afterRealCopy = ingest(
            &sampler,
            copiedBytes: 2_000_000,
            startedAt: startedAt,
            clock: clock,
            advance: 2,
            completed: 1,
            copied: 1,
            skippedExisting: 1,
            currentName: "copy-me.wav"
        )
        XCTAssertEqual(try XCTUnwrap(afterRealCopy.currentBytesPerSecond), 1_000_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(afterRealCopy.averageBytesPerSecond), 2_000_000.0 / 3.0, accuracy: 1)
    }

    func testCopyNowPublishesWindowSpeedNotCumulativeAverageAndByteFractionReachesOne()
        async throws
    {
        let fileSize: Int64 = 2_000_000
        let (model, scannedPlan, _) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var readings: [MediaCopySpeedReading] = []
        var lastReading: MediaCopySpeedReading?
        var sawDistinctWindow = false
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if let reading = model.mediaCopySpeedReading,
                lastReading.map({ $0 != reading }) ?? true
            {
                readings.append(reading)
                lastReading = reading
                if let current = reading.currentBytesPerSecond,
                    let average = reading.averageBytesPerSecond,
                    abs(current - average) > 1
                {
                    sawDistinctWindow = true
                }
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(
            sawDistinctWindow,
            "Copy Now must publish window speed, not the cumulative average"
        )
        XCTAssertEqual(model.mediaCopySpeedReading?.byteFractionCompleted, 1.0)
        XCTAssertEqual(model.mediaCopyProgress?.copiedBytes, scannedPlan.totalSizeBytes)
        XCTAssertFalse(readings.isEmpty)
    }

    func testCopyNowDoesNotRaiseStallOnInterFileBookkeeping() async throws {
        let (model, _, _) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: 2_000_000
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var sawStall = false
        var sawSecondFile = false
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if model.mediaCopyIsStalled {
                sawStall = true
            }
            if model.mediaCopyProgress?.currentName == "large-two.wav" {
                sawSecondFile = true
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(sawSecondFile)
        XCTAssertFalse(sawStall)
        XCTAssertFalse(model.mediaCopyIsStalled)
    }

    func testCopyNowRaisesStallDuringExecutorSilenceAndClearsWhenBytesResume() async throws {
        let fileSize: Int64 = 2_000_000
        let (model, scannedPlan, queueBefore) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        let scannedIDs = scannedPlan.candidates.map(\.id)
        let queueIDs = queueBefore.map(\.id)
        let scannedBytes = scannedPlan.totalSizeBytes
        MediaCopyTransactionExecutor.testSlowCopyChunkByteCount = 700_000
        MediaCopyTransactionExecutor.testSlowCopyChunkDelayNanoseconds = 3_500_000_000

        var sawInFlightIncrease = false
        var stalledWhileBytesFlat = false
        var bytesWhenStalled: Int64?
        var clearedAfterIncrease = false
        var lastReading: MediaCopySpeedReading?
        var identityDrift: String?
        var stallTickCount = 0
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 40) {
            guard let progress = model.mediaCopyProgress else { return false }
            if progress.copiedBytes > 0,
                progress.copiedBytes < fileSize,
                progress.currentName == "large-one.wav"
            {
                sawInFlightIncrease = true
            }
            if sawInFlightIncrease,
                model.mediaCopySpeedReading?.isStalled == true,
                progress.copiedBytes > 0,
                progress.copiedBytes < fileSize,
                progress.currentName == "large-one.wav"
            {
                stalledWhileBytesFlat = true
                bytesWhenStalled = progress.copiedBytes
            }
            if stalledWhileBytesFlat,
                model.mediaCopySpeedReading?.isStalled == false,
                progress.copiedBytes > (bytesWhenStalled ?? 0)
            {
                clearedAfterIncrease = true
            }
            if let reading = model.mediaCopySpeedReading,
                lastReading.map({ $0 != reading }) ?? true
            {
                let wasStalled = lastReading?.isStalled == true
                if reading.isStalled {
                    stallTickCount += 1
                    if model.mediaCopyQueue.map(\.id) != queueIDs {
                        identityDrift = "queue IDs changed during a stall tick"
                    } else if model.mediaCopyPlan?.candidates.map(\.id) != scannedIDs {
                        identityDrift = "plan candidate IDs changed during a stall tick"
                    } else if model.mediaCopyPlan?.totalSizeBytes != scannedBytes {
                        identityDrift = "scan-derived plan identity changed during a stall tick"
                    }
                } else if wasStalled, stalledWhileBytesFlat {
                    if model.mediaCopyQueue.map(\.id) != queueIDs {
                        identityDrift = "queue IDs changed on resume ingest that cleared stall"
                    } else if model.mediaCopyPlan?.candidates.map(\.id) != scannedIDs {
                        identityDrift = "plan candidate IDs changed on resume ingest that cleared stall"
                    } else if model.mediaCopyPlan?.totalSizeBytes != scannedBytes {
                        identityDrift = "scan-derived plan identity changed on resume ingest that cleared stall"
                    }
                }
                lastReading = reading
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(sawInFlightIncrease)
        XCTAssertTrue(
            stalledWhileBytesFlat,
            "stall must raise during executor silence while copiedBytes stay flat"
        )
        XCTAssertTrue(clearedAfterIncrease)
        XCTAssertFalse(model.mediaCopyIsStalled)
        XCTAssertGreaterThan(
            stallTickCount,
            0,
            "must observe stall ticks with queue and plan identity checks"
        )
        XCTAssertNil(identityDrift, identityDrift ?? "")
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), queueIDs)
        XCTAssertEqual(model.mediaCopyPlan?.candidates.map(\.id), scannedIDs)
        XCTAssertEqual(model.mediaCopyPlan?.totalSizeBytes, scannedBytes)
    }

    func testCopyNowDisplayShowsCurrentAverageByteFractionAndCalculatingSpeed() async throws {
        let fileSize: Int64 = 2_000_000
        let (model, _, _) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var sawCalculatingSpeed = false
        var sawCurrentAndAverage = false
        var sawByteFractionAlongsideCount = false
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if model.mediaCopyCurrentSpeedText == "Calculating speed" {
                sawCalculatingSpeed = true
            }
            let summary = model.mediaCopySpeedSummaryText
            if summary.contains("Current"),
                summary.contains("Average"),
                summary.contains("MB/s"),
                !model.mediaCopyIsStalled
            {
                sawCurrentAndAverage = true
            }
            if let progress = model.mediaCopyProgress,
                progress.copiedBytes > 0,
                progress.copiedBytes < fileSize,
                model.mediaCopyByteFractionCompleted > 0,
                model.mediaCopyByteFractionCompleted < 1,
                model.mediaCopyByteFractionText.contains("%"),
                model.mediaCopyCountCompletionText.contains("of")
            {
                sawByteFractionAlongsideCount = true
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(sawCalculatingSpeed)
        XCTAssertTrue(sawCurrentAndAverage)
        XCTAssertTrue(sawByteFractionAlongsideCount)
        XCTAssertEqual(model.mediaCopyByteFractionCompleted, 1.0)
        XCTAssertEqual(model.mediaCopyByteFractionText, "100% of bytes")
        XCTAssertEqual(model.mediaCopyCountCompletionText, "2 of 2")
        XCTAssertTrue(model.mediaCopySpeedSummaryText.contains("MB/s"))
        XCTAssertEqual(
            1_600_000.0.formattedMegabytesPerSecond,
            "1.6 MB/s"
        )
    }

    func testDisplayShowsStalledIndicationAndClearsWithSampler() {
        let model = makeMediaFileManagerModel()
        model.fileManagementMode = .copy
        model.mediaCopySpeedReading = MediaCopySpeedReading(
            currentBytesPerSecond: 0,
            averageBytesPerSecond: 1_200_000,
            isStalled: true,
            byteFractionCompleted: 0.4
        )
        XCTAssertTrue(model.mediaCopyIsStalled)
        XCTAssertTrue(model.mediaCopySpeedSummaryText.contains("Stalled"))
        XCTAssertEqual(model.mediaCopyAverageSpeedText, "1.2 MB/s")
        XCTAssertEqual(model.mediaCopyByteFractionText, "40% of bytes")

        model.mediaCopySpeedReading = MediaCopySpeedReading(
            currentBytesPerSecond: 1_600_000,
            averageBytesPerSecond: 1_200_000,
            isStalled: false,
            byteFractionCompleted: 0.5
        )
        XCTAssertFalse(model.mediaCopyIsStalled)
        XCTAssertFalse(model.mediaCopySpeedSummaryText.contains("Stalled"))
        XCTAssertEqual(model.mediaCopyCurrentSpeedText, "1.6 MB/s")
        XCTAssertTrue(model.mediaCopySpeedSummaryText.contains("Current"))
        XCTAssertTrue(model.mediaCopySpeedSummaryText.contains("Average"))
        XCTAssertTrue(model.mediaCopySpeedSummaryText.contains("MB/s"))
    }

    func testSpeedTicksDoNotInvalidateQueuePlanOrScanAndStayWithinPublicationCadence()
        async throws
    {
        let fileSize: Int64 = 2_000_000
        let (model, scannedPlan, queueBefore) = try await makeScannedCopyNowModel(
            firstName: "large-one.wav",
            secondName: "large-two.wav",
            fileSize: fileSize
        )
        let scannedIDs = scannedPlan.candidates.map(\.id)
        let queueIDs = queueBefore.map(\.id)
        let scannedBytes = scannedPlan.totalSizeBytes
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        var readings: [(Date, MediaCopySpeedReading)] = []
        var lastReading: MediaCopySpeedReading?
        var identityDrift: String?
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if let reading = model.mediaCopySpeedReading,
                lastReading.map({ $0 != reading }) ?? true
            {
                readings.append((Date(), reading))
                lastReading = reading
                if model.mediaCopyQueue.map(\.id) != queueIDs {
                    identityDrift = "queue IDs changed during a speed-derived update"
                } else if model.mediaCopyPlan?.candidates.map(\.id) != scannedIDs {
                    identityDrift = "plan candidate IDs changed during a speed-derived update"
                } else if model.mediaCopyPlan?.totalSizeBytes != scannedBytes {
                    identityDrift = "scan-derived plan identity changed during a speed-derived update"
                }
            }
            return !model.isMediaCopyBusy && model.mediaCopyProgress?.copied == 2
        }
        XCTAssertTrue(copied)
        XCTAssertNil(identityDrift, identityDrift ?? "")
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), queueIDs)
        XCTAssertEqual(model.mediaCopyPlan?.candidates.map(\.id), scannedIDs)
        XCTAssertEqual(model.mediaCopyPlan?.totalSizeBytes, scannedBytes)
        XCTAssertGreaterThanOrEqual(readings.count, 3)
        assertPublicationCadenceIsBounded(readings.map(\.0))
    }

    func testSkippedExistingFilesNeverCountAsThroughputOnCopyNow() async throws {
        let fileSize: Int64 = 2_000_000
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile("copy-me.wav", in: source, byteCount: fileSize, repeating: 0x11)
        try writeBinaryFile("already-there.wav", in: source, byteCount: fileSize, repeating: 0x22)
        try writeBinaryFile(
            "Source/already-there.wav",
            in: destination,
            byteCount: fileSize,
            repeating: 0x33
        )

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaCopyConflictResolutionHandler = { _ in .skipExisting }
        MediaCopyTransactionExecutor.installVirtualSlowCopyHook()

        model.scanMediaCopyFiles()
        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2 }
        XCTAssertTrue(scanned)

        var peakAverage: Double = 0
        var peakCurrent: Double = 0
        model.copyFilteredMediaFiles()
        let copied = await waitUntil(timeout: 15) {
            if let reading = model.mediaCopySpeedReading {
                peakAverage = max(peakAverage, reading.averageBytesPerSecond ?? 0)
                peakCurrent = max(peakCurrent, reading.currentBytesPerSecond ?? 0)
            }
            return !model.isMediaCopyBusy
                && model.mediaCopyProgress?.copied == 1
                && model.mediaCopyProgress?.skippedExisting == 1
        }
        XCTAssertTrue(copied)
        XCTAssertEqual(model.mediaCopyProgress?.copiedBytes, fileSize)
        XCTAssertEqual(model.mediaCopySpeedReading?.byteFractionCompleted, 1.0)
        XCTAssertLessThan(
            peakAverage,
            Double(fileSize) * 2 / 0.05,
            "skip must not treat destination-existing bytes as copied throughput"
        )
        XCTAssertGreaterThan(peakCurrent, 0)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Source/already-there.wav")),
            Data(repeating: 0x33, count: Int(fileSize))
        )
    }

    @discardableResult
    private func ingest(
        _ sampler: inout MediaCopySpeedSampler,
        copiedBytes: Int64,
        totalBytes: Int64 = 40_000_000,
        startedAt: Date,
        clock: TestClock,
        advance: TimeInterval,
        completed: Int = 0,
        total: Int = 2,
        copied: Int = 0,
        skippedExisting: Int = 0,
        currentName: String? = "large-one.wav"
    ) -> MediaCopySpeedReading {
        clock.advance(advance)
        let progress = MediaCopyProgress(
            completed: completed,
            total: total,
            copied: copied,
            skippedExisting: skippedExisting,
            failed: 0,
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            startedAt: startedAt,
            updatedAt: clock.now,
            currentName: currentName
        )
        return sampler.ingest(progress)
    }

    private func makeScannedCopyNowModel(
        firstName: String,
        secondName: String,
        fileSize: Int64
    ) async throws -> (EncoderViewModel, MediaCopyBatchPlan, [MediaCopyWorkflow]) {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeBinaryFile(firstName, in: source, byteCount: fileSize, repeating: 0x41)
        try writeBinaryFile(secondName, in: source, byteCount: fileSize, repeating: 0x42)

        let model = makeMediaFileManagerModel()
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaCopyConflictResolutionHandler = { _ in .replaceExisting }

        model.scanMediaCopyFiles()
        let scanned = await waitUntil { !model.isMediaCopyBusy && model.mediaCopyMatchedCount == 2 }
        XCTAssertTrue(scanned)
        let scannedPlan = try XCTUnwrap(model.mediaCopyPlan)
        return (model, scannedPlan, model.mediaCopyQueue)
    }

    private func assertPublicationCadenceIsBounded(_ timestamps: [Date]) {
        let maximumPublicationsPerSecond = 8.0
        guard timestamps.count >= 2 else { return }
        let elapsed = timestamps.last!.timeIntervalSince(timestamps.first!)
        let rate = Double(timestamps.count - 1) / max(elapsed, 0.001)
        XCTAssertLessThanOrEqual(
            rate,
            maximumPublicationsPerSecond,
            "speed ticks must stay within the 002 publication cadence; rate=\(rate) count=\(timestamps.count) elapsed=\(elapsed)"
        )
    }

    private final class TestClock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }

        func advance(_ interval: TimeInterval) {
            now = now.addingTimeInterval(interval)
        }
    }

    private func makeMediaFileManagerModel() -> EncoderViewModel {
        let queueStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GPhilCoderTests-QueueStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryDirectories.append(queueStorageRoot)
        let model = EncoderViewModel(mediaCopyQueueStorageRoot: queueStorageRoot)
        model.completionNotificationsEnabled = false
        model.fileManagementMode = .copy
        model.mediaCopyFilter = .audio
        model.mediaFileNameFilterQuery = ""
        model.selectAllMediaCopyExtensions()
        return model
    }

    private func clearMediaFileManagerDefaultsForTests() {
        clearViewModelDefaultsForTests()
        let keys = [
            "completionNotificationsEnabled",
            "mediaCopySourceRootPath",
            "mediaCopySourceRootPaths",
            "mediaCopyDestinationRootPath",
            "mediaCopyDestinationLayout",
            "mediaCopyFilter",
            "mediaCopyAudioExtensions",
            "mediaCopyVideoExtensions",
            "mediaFileNameFilterQuery",
            "mediaRenameSettings",
            "mediaRenameHistory"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeBinaryFile(
        _ path: String,
        in root: URL,
        byteCount: Int64,
        repeating byte: UInt8
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: byte, count: Int(byteCount)).write(to: url)
        return url
    }
}
