import Foundation

public enum MediaCopySavedWorkflowLibraryDocumentError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let supported):
            "This saved copy-workflow library uses version \(found), but this GPhil MediaFlow build supports up to version \(supported). Update GPhil MediaFlow or repair the library file."
        }
    }
}

/// One named saved copy queue. The user-facing identity is the trimmed name;
/// `id` stays stable across overwrite-same-name. Workflows reuse the existing
/// `MediaCopyWorkflow` payload (ids, order, roots, layout, filters).
public struct MediaCopySavedWorkflow: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var savedAt: Date
    public var workflows: [MediaCopyWorkflow]

    public init(
        id: UUID = UUID(),
        name: String,
        savedAt: Date = Date(),
        workflows: [MediaCopyWorkflow]
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.workflows = workflows
    }
}

public struct MediaCopySavedWorkflowLibraryDocument: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case savedAt
        case items
    }

    public static let currentVersion = 1

    public let version: Int
    public let savedAt: Date
    public let items: [MediaCopySavedWorkflow]

    public init(
        version: Int = Self.currentVersion,
        savedAt: Date = Date(),
        items: [MediaCopySavedWorkflow]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw MediaCopySavedWorkflowLibraryDocumentError.unsupportedVersion(
                found: storedVersion,
                supported: Self.currentVersion
            )
        }
        version = Self.currentVersion
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        items = try container.decode([MediaCopySavedWorkflow].self, forKey: .items)
    }
}
