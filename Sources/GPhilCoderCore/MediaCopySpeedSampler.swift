import Foundation

public struct MediaCopySpeedReading: Equatable, Sendable {
    public var currentBytesPerSecond: Double?
    public var averageBytesPerSecond: Double?
    public var isStalled: Bool
    public var byteFractionCompleted: Double

    public init(
        currentBytesPerSecond: Double?,
        averageBytesPerSecond: Double?,
        isStalled: Bool,
        byteFractionCompleted: Double
    ) {
        self.currentBytesPerSecond = currentBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.isStalled = isStalled
        self.byteFractionCompleted = byteFractionCompleted
    }
}

public struct MediaCopySpeedSampler {
    public static let defaultWindowDuration: TimeInterval = 10
    public static let defaultStallDuration: TimeInterval = 3

    private let windowDuration: TimeInterval
    private let stallDuration: TimeInterval
    private let now: () -> Date
    private var samples: [Sample] = []
    private var lastProgress: MediaCopyProgress?
    private var lastByteIncreaseAt: Date?
    private var isTransferInFlight = false
    private var lastCompleted = 0
    private var lastCurrentName: String?

    public init(
        windowDuration: TimeInterval = defaultWindowDuration,
        stallDuration: TimeInterval = defaultStallDuration,
        now: @escaping () -> Date = { Date() }
    ) {
        self.windowDuration = windowDuration
        self.stallDuration = stallDuration
        self.now = now
    }

    var retainedSampleCount: Int { samples.count }

    public mutating func ingest(_ progress: MediaCopyProgress) -> MediaCopySpeedReading {
        let timestamp = now()
        let previousBytes = samples.last?.copiedBytes ?? 0
        let delta = progress.copiedBytes - previousBytes

        if progress.copiedBytes == 0, samples.last?.copiedBytes == 0 {
            samples.removeLast()
        }
        samples.append(Sample(date: timestamp, copiedBytes: progress.copiedBytes))

        if delta > 0 {
            lastByteIncreaseAt = timestamp
            isTransferInFlight = true
        }
        if progress.completed > lastCompleted || progress.currentName == nil {
            isTransferInFlight = false
        } else if progress.currentName != lastCurrentName, delta <= 0 {
            isTransferInFlight = false
        }

        lastCompleted = progress.completed
        lastCurrentName = progress.currentName
        lastProgress = progress
        pruneSamples(at: timestamp)
        return makeReading(for: progress, at: timestamp)
    }

    /// Re-evaluates the last in-flight snapshot against the injected clock
    /// without recording a new byte-moved sample.
    public mutating func tick() -> MediaCopySpeedReading? {
        guard let progress = lastProgress else { return nil }
        let timestamp = now()
        pruneSamples(at: timestamp)
        return makeReading(for: progress, at: timestamp)
    }

    public mutating func reset() {
        samples = []
        lastProgress = nil
        lastByteIncreaseAt = nil
        isTransferInFlight = false
        lastCompleted = 0
        lastCurrentName = nil
    }

    private mutating func pruneSamples(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-windowDuration)
        let inWindow = samples.filter { $0.date > cutoff }
        if let baseline = samples.last(where: { $0.date <= cutoff }) {
            samples = [baseline] + inWindow
        } else {
            samples = inWindow
        }
    }

    private func makeReading(
        for progress: MediaCopyProgress,
        at timestamp: Date
    ) -> MediaCopySpeedReading {
        let stalled = isTransferInFlight
            && lastByteIncreaseAt.map { timestamp.timeIntervalSince($0) >= stallDuration } ?? false
        return MediaCopySpeedReading(
            currentBytesPerSecond: windowSpeed(at: timestamp),
            averageBytesPerSecond: averageSpeed(for: progress, at: timestamp),
            isStalled: stalled,
            byteFractionCompleted: byteFraction(for: progress)
        )
    }

    private func windowSpeed(at timestamp: Date) -> Double? {
        let windowSamples = samplesInWindow(at: timestamp)
        guard let newest = windowSamples.last, newest.copiedBytes > 0 else { return nil }
        guard windowSamples.count >= 2 else { return 0 }
        let oldest = windowSamples[0]
        let elapsed = timestamp.timeIntervalSince(oldest.date)
        guard elapsed > 0 else { return nil }
        return Double(newest.copiedBytes - oldest.copiedBytes) / elapsed
    }

    private func samplesInWindow(at timestamp: Date) -> [Sample] {
        let cutoff = timestamp.addingTimeInterval(-windowDuration)
        let inWindow = samples.filter { $0.date > cutoff }
        if let baseline = samples.last(where: { $0.date <= cutoff }) {
            return [baseline] + inWindow
        }
        return inWindow
    }

    private func averageSpeed(for progress: MediaCopyProgress, at timestamp: Date) -> Double? {
        guard progress.copiedBytes > 0 else { return nil }
        let elapsed = timestamp.timeIntervalSince(progress.startedAt)
        guard elapsed > 0 else { return nil }
        return Double(progress.copiedBytes) / elapsed
    }

    private func byteFraction(for progress: MediaCopyProgress) -> Double {
        if progress.total > 0, progress.completed >= progress.total {
            return 1
        }
        guard progress.totalBytes > 0 else {
            return progress.copiedBytes > 0 ? 1 : 0
        }
        return min(1, max(0, Double(progress.copiedBytes) / Double(progress.totalBytes)))
    }

    private struct Sample: Sendable {
        var date: Date
        var copiedBytes: Int64
    }
}
