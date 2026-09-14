import Darwin
import Foundation
import GPhilCoderCore

enum MediaCopyByteReportingCopy {
    static let minimumPublicationInterval: TimeInterval = 0.125
    static let defaultChunkByteCount = 1_048_576
    static let largeRegularFileThreshold: Int64 = 65_536

    static func shouldReportBytes(for candidate: MediaCopyCandidate, force: Bool) -> Bool {
        guard !candidate.isPackage else { return false }
        guard candidate.fileSizeBytes > 0 else { return false }
        return force || candidate.fileSizeBytes >= largeRegularFileThreshold
    }

    static func copyRegularFile(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        chunkByteCount: Int,
        chunkDelayNanoseconds: UInt64?,
        isCancelled: @escaping @Sendable () -> Bool,
        onBytesCopied: @escaping @Sendable (Int64) -> Void
    ) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let chunkSize = max(chunkByteCount, 1)
        var written: Int64 = 0
        var lastPublishedAt = Date.distantPast

        while true {
            if isCancelled() {
                throw CancellationError()
            }
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }
            try output.write(contentsOf: data)
            try output.synchronize()
            written += Int64(data.count)
            let reported = min(written, expectedSize)
            if reported > 0 && reported < expectedSize {
                let now = Date()
                if now.timeIntervalSince(lastPublishedAt) >= minimumPublicationInterval {
                    onBytesCopied(reported)
                    lastPublishedAt = now
                }
            }
            if let chunkDelayNanoseconds, chunkDelayNanoseconds > 0 {
                Thread.sleep(forTimeInterval: Double(chunkDelayNanoseconds) / 1_000_000_000)
            }
        }

        try copyMetadata(from: source, to: destination)
    }

    private static func copyMetadata(from source: URL, to destination: URL) throws {
        let flags =
            copyfile_flags_t(COPYFILE_XATTR)
            | copyfile_flags_t(COPYFILE_ACL)
            | copyfile_flags_t(COPYFILE_STAT)
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

final class MediaCopyByteProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBytes: Int64?
    private var finishedEvidence: MediaCopyPathEvidence?
    private var finishedError: Error?
    private var isFinished = false
    private var cancelRequested = false

    func requestCancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    func isCancelRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    func report(bytes: Int64) {
        lock.lock()
        latestBytes = bytes
        lock.unlock()
    }

    func finish(evidence: MediaCopyPathEvidence) {
        lock.lock()
        finishedEvidence = evidence
        isFinished = true
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        finishedError = error
        isFinished = true
        lock.unlock()
    }

    func takeUpdate() -> (bytes: Int64?, isFinished: Bool, evidence: MediaCopyPathEvidence?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        let bytes = latestBytes
        latestBytes = nil
        return (bytes, isFinished, finishedEvidence, finishedError)
    }
}
