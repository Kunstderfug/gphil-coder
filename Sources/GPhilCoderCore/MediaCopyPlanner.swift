import Foundation

public enum MediaFileFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case audio
    case video

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            "All Files"
        case .audio:
            "Audio"
        case .video:
            "Video"
        }
    }

    public var fileTypeName: String {
        switch self {
        case .all:
            "matching"
        case .audio:
            "audio"
        case .video:
            "video"
        }
    }

    public var symbolName: String {
        switch self {
        case .all:
            "folder"
        case .audio:
            "music.note"
        case .video:
            "film"
        }
    }

    public var fileExtensions: Set<String> {
        switch self {
        case .all:
            []
        case .audio:
            [
                "aac", "ac3", "aif", "aifc", "aiff", "ape", "caf", "flac", "m4a", "mka",
                "mp3", "ogg", "opus", "wav", "wma", "wv"
            ]
        case .video:
            [
                "3g2", "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg",
                "mpg", "mts", "mxf", "ogv", "ts", "vob", "webm", "wmv"
            ]
        }
    }

    public var readableExtensions: String {
        guard self != .all else { return "All files and folders" }
        return fileExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }

    public func matches(_ url: URL) -> Bool {
        guard self != .all else { return true }
        return fileExtensions.contains(url.pathExtension.lowercased())
    }
}

public enum MediaCopyConflictResolution: Sendable {
    case skipExisting
    case replaceExisting
}

public enum MediaCopyItemResult: Equatable, Sendable {
    case copied
    case skippedExisting
    case failed(String)
}

public struct MediaCopyCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let destinationURL: URL
    public let relativePath: String
    public let fileSizeBytes: Int64
    public let hasDestinationConflict: Bool

    public init(
        id: String,
        sourceURL: URL,
        destinationURL: URL,
        relativePath: String,
        fileSizeBytes: Int64,
        hasDestinationConflict: Bool
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.hasDestinationConflict = hasDestinationConflict
    }

    public var name: String {
        sourceURL.lastPathComponent
    }
}

public struct MediaCopyPlan: Sendable {
    public let sourceRoot: URL
    public let destinationRoot: URL
    public let filter: MediaFileFilter
    public let candidates: [MediaCopyCandidate]
    public let relativeDirectories: [String]
    public let scannedAt: Date

    public init(
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        candidates: [MediaCopyCandidate],
        relativeDirectories: [String] = [],
        scannedAt: Date
    ) {
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.filter = filter
        self.candidates = candidates
        self.relativeDirectories = relativeDirectories
        self.scannedAt = scannedAt
    }

    public var hasCopyableContent: Bool {
        !candidates.isEmpty || !relativeDirectories.isEmpty
    }

    public var totalSizeBytes: Int64 {
        candidates.reduce(0) { $0 + $1.fileSizeBytes }
    }

    public var conflictCount: Int {
        candidates.filter(\.hasDestinationConflict).count
    }

    public var copyableWithoutOverwriteCount: Int {
        candidates.count - conflictCount
    }

    public var directoryCount: Int {
        relativeDirectories.count
    }
}

public struct MediaCopyProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let copied: Int
    public let skippedExisting: Int
    public let failed: Int
    public let currentName: String?

    public init(
        completed: Int,
        total: Int,
        copied: Int,
        skippedExisting: Int,
        failed: Int,
        currentName: String?
    ) {
        self.completed = completed
        self.total = total
        self.copied = copied
        self.skippedExisting = skippedExisting
        self.failed = failed
        self.currentName = currentName
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

public struct MediaCopyResult: Sendable {
    public var total: Int
    public var copied: Int
    public var skippedExisting: Int
    public var failed: Int
    public var failedNames: [String]
    public var createdDirectories: Int
    public var failedDirectories: Int
    public var failedDirectoryNames: [String]
    public var cancelled: Bool

    public init(
        total: Int = 0,
        copied: Int = 0,
        skippedExisting: Int = 0,
        failed: Int = 0,
        failedNames: [String] = [],
        createdDirectories: Int = 0,
        failedDirectories: Int = 0,
        failedDirectoryNames: [String] = [],
        cancelled: Bool = false
    ) {
        self.total = total
        self.copied = copied
        self.skippedExisting = skippedExisting
        self.failed = failed
        self.failedNames = failedNames
        self.createdDirectories = createdDirectories
        self.failedDirectories = failedDirectories
        self.failedDirectoryNames = failedDirectoryNames
        self.cancelled = cancelled
    }
}

public struct MediaCopyWorkflow: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var sourceRoot: URL
    public var destinationRoot: URL
    public var filter: MediaFileFilter
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.filter = filter
        self.createdAt = createdAt
    }

    public var destinationRootPreservingSourceFolder: URL {
        let sourceFolderName = sourceRoot.lastPathComponent
        guard !sourceFolderName.isEmpty else { return destinationRoot }

        if destinationRoot.lastPathComponent == sourceFolderName {
            return destinationRoot
        }

        return destinationRoot.appendingPathComponent(sourceFolderName, isDirectory: true)
    }
}

public struct MediaCopyJobDocument: Codable, Sendable {
    public static let currentVersion = 1

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
}

public enum MediaCopyPlanner {
    public static func buildPlan(
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter
    ) throws -> MediaCopyPlan {
        var candidates: [MediaCopyCandidate] = []
        var relativeDirectories: [String] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]

        guard
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        for case let sourceURL as URL in enumerator {
            try Task.checkCancellation()

            let values = try? sourceURL.resourceValues(forKeys: Set(keys))

            if filter == .all, values?.isDirectory == true,
                let relativeComponents = relativePathComponents(
                    for: sourceURL,
                    sourceRoot: sourceRoot
                )
            {
                relativeDirectories.append(relativeComponents.joined(separator: "/"))
                continue
            }

            guard values?.isRegularFile == true, filter.matches(sourceURL) else { continue }

            guard let relativeComponents = relativePathComponents(
                for: sourceURL,
                sourceRoot: sourceRoot
            ) else {
                continue
            }

            let destinationURL = appendingPathComponents(
                relativeComponents,
                to: destinationRoot
            )
            let relativePath = relativeComponents.joined(separator: "/")
            let destinationConflict = fileManager.fileExists(atPath: destinationURL.path)

            candidates.append(
                MediaCopyCandidate(
                    id: sourceURL.standardizedFileURL.path,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    relativePath: relativePath,
                    fileSizeBytes: values?.fileSize.map(Int64.init) ?? 0,
                    hasDestinationConflict: destinationConflict
                )
            )
        }

        candidates.sort {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
        relativeDirectories.sort {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        return MediaCopyPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: filter,
            candidates: candidates,
            relativeDirectories: relativeDirectories,
            scannedAt: Date()
        )
    }

    public static func createDirectories(for plan: MediaCopyPlan) -> [String] {
        createDirectories(plan.relativeDirectories, at: plan.destinationRoot)
    }

    public static func createDirectories(
        _ relativeDirectories: [String],
        at destinationRoot: URL
    ) -> [String] {
        let fileManager = FileManager.default
        var failures: [String] = []

        for relativeDirectory in relativeDirectories {
            let directoryURL = destinationRoot.appendingPathComponent(
                relativeDirectory,
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                failures.append(relativeDirectory)
            }
        }

        return failures
    }

    public static func copyCandidate(
        _ candidate: MediaCopyCandidate,
        conflictResolution: MediaCopyConflictResolution
    ) -> MediaCopyItemResult {
        let fileManager = FileManager.default
        let destinationDirectory = candidate.destinationURL.deletingLastPathComponent()
        var temporaryURL: URL?

        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            var isDirectory: ObjCBool = false
            let destinationExists = fileManager.fileExists(
                atPath: candidate.destinationURL.path,
                isDirectory: &isDirectory
            )

            if destinationExists && isDirectory.boolValue {
                return .failed(candidate.relativePath)
            }

            if destinationExists && conflictResolution == .skipExisting {
                return .skippedExisting
            }

            if destinationExists {
                let tempURL = destinationDirectory.appendingPathComponent(
                    ".gphilcoder-\(UUID().uuidString).tmp",
                    isDirectory: false
                )
                temporaryURL = tempURL
                try fileManager.copyItem(at: candidate.sourceURL, to: tempURL)
                _ = try fileManager.replaceItemAt(
                    candidate.destinationURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.copyItem(at: candidate.sourceURL, to: candidate.destinationURL)
            }

            return .copied
        } catch {
            if let temporaryURL, fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            return .failed(candidate.relativePath)
        }
    }

    static func relativePathComponents(
        for url: URL,
        sourceRoot: URL
    ) -> [String]? {
        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents

        guard itemComponents.count > rootComponents.count,
            Array(itemComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        return Array(itemComponents.dropFirst(rootComponents.count))
    }

    static func appendingPathComponents(
        _ components: [String],
        to root: URL
    ) -> URL {
        components.enumerated().reduce(root) { partialURL, element in
            let isLast = element.offset == components.count - 1
            return partialURL.appendingPathComponent(element.element, isDirectory: !isLast)
        }
    }
}
