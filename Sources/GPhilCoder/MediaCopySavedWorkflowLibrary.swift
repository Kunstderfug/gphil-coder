import Foundation
import GPhilCoderCore

/// Durable storage for the named File Copy saved-queue library.
///
/// This is a different document from the last-session `MediaCopyQueueStore`.
/// It owns the named list only: each item embeds existing `MediaCopyWorkflow`
/// values. Writes are atomic. A corrupt or future-version document is
/// quarantined best-effort as a timestamped sidecar, mirroring
/// `MediaCopyQueueStore` / `SettingsPersistence.preserveCorruptBlob`.
struct MediaCopySavedWorkflowLibrary {
    enum LoadOutcome: Equatable {
        case noDocument
        case restored(items: [MediaCopySavedWorkflow])
        case quarantined(problem: String)
    }

    static let documentName = "MediaCopySavedWorkflows"
    private static let documentFileExtension = "json"
    private static let corruptFileExtension = "corrupt"
    private static let liveDirectoryName = "MediaCopySavedWorkflows"

    let directoryURL: URL
    let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// Live per-user location: `Application Support/GPhilCoder/MediaCopySavedWorkflows/`,
    /// a sibling of the last-session `MediaCopyQueue` directory.
    static func liveDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("GPhilCoder", isDirectory: true)
            .appendingPathComponent(liveDirectoryName, isDirectory: true)
    }

    var documentURL: URL {
        directoryURL
            .appendingPathComponent(Self.documentName, isDirectory: false)
            .appendingPathExtension(Self.documentFileExtension)
    }

    /// Loads the named library. Decoding completes before the caller replaces
    /// the published list. A missing document is an empty list and must not
    /// write a file.
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
            let document = try decoder.decode(
                MediaCopySavedWorkflowLibraryDocument.self,
                from: data
            )
            let items = document.items.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return .restored(items: items)
        } catch {
            let problem = Self.problemDescription(for: error)
            quarantine(data)
            return .quarantined(problem: problem)
        }
    }

    /// Atomically persists the named list. Callers must not invoke this for a
    /// missing document at composition.
    func save(_ items: [MediaCopySavedWorkflow]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            MediaCopySavedWorkflowLibraryDocument(items: items)
        )
        try data.write(to: documentURL, options: [.atomic])
    }

    /// Best-effort quarantine: the unreadable bytes survive in a timestamped
    /// sidecar and the broken document is removed only after the sidecar write
    /// succeeded. If the quarantine fails, the original document is left
    /// exactly as it was.
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
        if let documentError = error as? MediaCopySavedWorkflowLibraryDocumentError {
            return documentError.errorDescription ?? String(describing: documentError)
        }
        return error.localizedDescription
    }
}
