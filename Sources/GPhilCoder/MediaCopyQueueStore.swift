import Foundation
import GPhilCoderCore

/// Durable storage for the file-copy workflow queue.
///
/// The queue and saved `.job` files share one document semantics: this store
/// reads and writes exactly one versioned `MediaCopyJobDocument`, so a
/// relaunch restores the same shape that a manual Save/Load Job round-trips
/// (versions 1–2 decode, with v1 migrating; anything above the current
/// version is rejected by the existing version gate). Writes are atomic. A
/// corrupt or future-version document is quarantined best-effort as a
/// timestamped sidecar, mirroring `SettingsPersistence.preserveCorruptBlob`,
/// so unreadable bytes are never silently destroyed.
struct MediaCopyQueueStore {
    enum LoadOutcome: Equatable {
        case noDocument
        case restored(workflows: [MediaCopyWorkflow])
        case quarantined(problem: String)
    }

    static let documentName = "MediaCopyQueue"
    private static let documentFileExtension = "json"
    private static let corruptFileExtension = "corrupt"

    let directoryURL: URL
    let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// The live per-user location: `Application Support/GPhilCoder/MediaCopyQueue/`.
    static func liveDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("GPhilCoder", isDirectory: true)
            .appendingPathComponent("MediaCopyQueue", isDirectory: true)
    }

    var documentURL: URL {
        directoryURL
            .appendingPathComponent(Self.documentName, isDirectory: false)
            .appendingPathExtension(Self.documentFileExtension)
    }

    /// Loads the persisted queue. Decoding completes before the caller replaces
    /// the in-memory queue, so a rejected document can never partially load.
    func load() -> LoadOutcome {
        guard fileManager.fileExists(atPath: documentURL.path) else { return .noDocument }

        let data: Data
        do {
            data = try Data(contentsOf: documentURL)
        } catch {
            return .quarantined(problem: error.localizedDescription)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(MediaCopyJobDocument.self, from: data)
            return .restored(workflows: document.workflows)
        } catch {
            let problem = Self.problemDescription(for: error)
            quarantine(data)
            return .quarantined(problem: problem)
        }
    }

    /// Atomically persists the queue as the versioned document. A cleared
    /// queue persists an empty workflows array, so a clear is durable.
    func save(_ workflows: [MediaCopyWorkflow]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(MediaCopyJobDocument(workflows: workflows))
        try data.write(to: documentURL, options: [.atomic])
    }

    /// Best-effort quarantine mirroring `SettingsPersistence.preserveCorruptBlob`:
    /// the unreadable bytes survive in a timestamped sidecar and the broken
    /// document is removed only after the sidecar write succeeded. If the
    /// quarantine fails, the original document is left exactly as it was.
    private func quarantine(_ data: Data) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let sidecar = directoryURL.appendingPathComponent(
                "\(Self.documentName)-\(timestamp).\(Self.corruptFileExtension)",
                isDirectory: false
            )
            try data.write(to: sidecar, options: [.atomic])
            try? fileManager.removeItem(at: documentURL)
        } catch {
            // Best-effort: the original document stays in place untouched.
        }
    }

    private static func problemDescription(for error: Error) -> String {
        if let documentError = error as? MediaCopyJobDocumentError {
            return documentError.errorDescription ?? String(describing: documentError)
        }
        return error.localizedDescription
    }
}
