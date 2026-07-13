import Foundation

private func localMediaCopyDirectoryURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.path(percentEncoded: false), isDirectory: true)
}

private struct LegacyMediaCopyWorkflow: Decodable {
    let id: UUID
    let sourceRoot: URL
    let destinationRoot: URL
    let filter: MediaFileFilter
    let selectedExtensions: Set<String>?
    let fileNameFilter: MediaFileNameFilter?
    let createdAt: Date

    var migrated: MediaCopyWorkflow {
        let source = localMediaCopyDirectoryURL(sourceRoot)
        let selectedDestination = localMediaCopyDirectoryURL(destinationRoot)
        let formerQueueDestination =
            selectedDestination.lastPathComponent == source.lastPathComponent
            ? selectedDestination
            : selectedDestination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        return MediaCopyWorkflow(
            id: id,
            sourceRoots: [source],
            destinationRoot: formerQueueDestination,
            destinationLayout: .mergeContents,
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter ?? MediaFileNameFilter(),
            createdAt: createdAt
        )
    }
}

public enum MediaCopyJobDocumentError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(found: Int, supported: Int)
    case emptySourceSet

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let supported):
            "This file copy job uses version \(found), but this GPhilCoder build supports up to version \(supported). Update GPhilCoder or open a compatible job file."
        case .emptySourceSet:
            "A saved file copy workflow has no source folders. The job file was left unchanged."
        }
    }
}

public enum MediaCopyWorkflowRepairIssue: Equatable, Sendable {
    case missingSource(URL)
    case missingDestination(URL)

    public var url: URL {
        switch self {
        case .missingSource(let url), .missingDestination(let url):
            url
        }
    }
}

public struct MediaCopyWorkflow: Codable, Hashable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceRoots
        case destinationRoot
        case destinationLayout
        case filter
        case selectedExtensions
        case fileNameFilter
        case createdAt
    }

    public let id: UUID
    public var sourceRoots: [URL]
    public var destinationRoot: URL
    public var destinationLayout: MediaCopyDestinationLayout
    public var filter: MediaFileFilter
    public var selectedExtensions: Set<String>?
    public var fileNameFilter: MediaFileNameFilter
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceRoots: [URL],
        destinationRoot: URL,
        destinationLayout: MediaCopyDestinationLayout = .sourceFolders,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>? = nil,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        createdAt: Date = Date()
    ) {
        precondition(!sourceRoots.isEmpty, "A file copy workflow requires at least one source folder.")
        self.id = id
        self.sourceRoots = sourceRoots
        self.destinationRoot = destinationRoot
        self.destinationLayout = destinationLayout
        self.filter = filter
        self.selectedExtensions = selectedExtensions
        self.fileNameFilter = fileNameFilter
        self.createdAt = createdAt
    }

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>? = nil,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            sourceRoots: [sourceRoot],
            destinationRoot: destinationRoot,
            destinationLayout: .sourceFolders,
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter,
            createdAt: createdAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceRoots = try container.decode([URL].self, forKey: .sourceRoots)
            .map(localMediaCopyDirectoryURL)
        guard !sourceRoots.isEmpty else { throw MediaCopyJobDocumentError.emptySourceSet }
        destinationRoot = localMediaCopyDirectoryURL(
            try container.decode(URL.self, forKey: .destinationRoot)
        )
        destinationLayout =
            try container.decodeIfPresent(MediaCopyDestinationLayout.self, forKey: .destinationLayout)
            ?? .sourceFolders
        filter = try container.decode(MediaFileFilter.self, forKey: .filter)
        selectedExtensions = try container.decodeIfPresent(Set<String>.self, forKey: .selectedExtensions)
        fileNameFilter =
            try container.decodeIfPresent(MediaFileNameFilter.self, forKey: .fileNameFilter)
            ?? MediaFileNameFilter()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceRoots, forKey: .sourceRoots)
        try container.encode(destinationRoot, forKey: .destinationRoot)
        try container.encode(destinationLayout, forKey: .destinationLayout)
        try container.encode(filter, forKey: .filter)
        try container.encodeIfPresent(selectedExtensions, forKey: .selectedExtensions)
        try container.encode(fileNameFilter, forKey: .fileNameFilter)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public var configuration: MediaCopyBatchConfiguration {
        MediaCopyBatchConfiguration(
            sourceRoots: sourceRoots,
            destinationRoot: destinationRoot,
            destinationLayout: destinationLayout,
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter
        )
    }

    public var repairIssues: [MediaCopyWorkflowRepairIssue] {
        var issues: [MediaCopyWorkflowRepairIssue] = sourceRoots.compactMap { sourceRoot in
            Self.directoryExists(at: sourceRoot)
                ? nil
                : MediaCopyWorkflowRepairIssue.missingSource(sourceRoot)
        }
        if !Self.directoryExists(at: destinationRoot) {
            issues.append(.missingDestination(destinationRoot))
        }
        return issues
    }

    public func replacingSourceRoot(_ sourceRoot: URL, with replacement: URL) -> Self {
        var updated = self
        let sourcePath = sourceRoot.standardizedFileURL.path
        updated.sourceRoots = sourceRoots.map {
            $0.standardizedFileURL.path == sourcePath ? replacement : $0
        }
        return updated
    }

    public func replacingDestinationRoot(with replacement: URL) -> Self {
        var updated = self
        updated.destinationRoot = replacement
        return updated
    }

    public var sourceRoot: URL {
        sourceRoots[0]
    }

    public var destinationRootPreservingSourceFolder: URL {
        destinationLayout.resolvedDestinationRoot(
            for: sourceRoot,
            destinationRoot: destinationRoot
        )
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

}

public struct MediaCopyJobDocument: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case savedAt
        case workflows
    }

    public static let currentVersion = 2

    public let version: Int
    public let savedAt: Date
    public let workflows: [MediaCopyWorkflow]

    public init(
        version: Int = Self.currentVersion,
        savedAt: Date = Date(),
        workflows: [MediaCopyWorkflow]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.workflows = workflows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw MediaCopyJobDocumentError.unsupportedVersion(
                found: storedVersion,
                supported: Self.currentVersion
            )
        }
        version = Self.currentVersion
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        if storedVersion == 1 {
            workflows = try container.decode([LegacyMediaCopyWorkflow].self, forKey: .workflows)
                .map(\.migrated)
        } else {
            workflows = try container.decode([MediaCopyWorkflow].self, forKey: .workflows)
        }
    }
}
