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

    public var supportsExtensionSelection: Bool {
        self != .all
    }

    public func effectiveExtensions(selectedExtensions: Set<String>? = nil) -> Set<String> {
        guard supportsExtensionSelection else { return [] }
        guard let selectedExtensions else { return fileExtensions }
        return Set(selectedExtensions.map { $0.lowercased() }).intersection(fileExtensions)
    }

    public var readableExtensions: String {
        readableExtensionList()
    }

    public func readableExtensionList(selectedExtensions: Set<String>? = nil) -> String {
        guard self != .all else { return "All files and folders" }
        let extensions = effectiveExtensions(selectedExtensions: selectedExtensions)
        guard !extensions.isEmpty else { return "No extensions selected" }
        return extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }

    public func compactExtensionSummary(selectedExtensions: Set<String>? = nil) -> String {
        guard supportsExtensionSelection else { return "All files" }
        let extensions = effectiveExtensions(selectedExtensions: selectedExtensions)
        guard !extensions.isEmpty else { return "No extensions" }
        guard extensions != fileExtensions else { return "All \(title.lowercased()) extensions" }
        if extensions.count == 1, let onlyExtension = extensions.first {
            return ".\(onlyExtension)"
        }
        return "\(extensions.count) extensions"
    }

    public func matches(_ url: URL, selectedExtensions: Set<String>? = nil) -> Bool {
        guard self != .all else { return true }
        return effectiveExtensions(selectedExtensions: selectedExtensions)
            .contains(url.pathExtension.lowercased())
    }
}

public struct MediaFileNameFilter: Codable, Hashable, Sendable {
    public var query: String

    public init(query: String = "") {
        self.query = query
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActive: Bool {
        !trimmedQuery.isEmpty
    }

    public func matches(_ url: URL) -> Bool {
        matches(fileName: url.lastPathComponent)
    }

    public func matches(fileName: String) -> Bool {
        let query = normalizedQuery
        guard !query.isEmpty else { return true }
        return Self.normalizedFileName(fileName).contains(query)
    }

    public func matches(normalizedFileName: String) -> Bool {
        let query = normalizedQuery
        guard !query.isEmpty else { return true }
        return normalizedFileName.contains(query)
    }

    public var normalizedQuery: String {
        Self.normalizedFileName(trimmedQuery)
    }

    public static func normalizedFileName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
    public let sourceRoot: URL
    public let destinationURL: URL
    public let relativePath: String
    public let fileSizeBytes: Int64
    public let hasDestinationConflict: Bool
    public let isPackage: Bool
    public let sourceEvidence: MediaCopyPathEvidence

    public init(
        id: String,
        sourceURL: URL,
        sourceRoot: URL,
        destinationURL: URL,
        relativePath: String,
        fileSizeBytes: Int64,
        hasDestinationConflict: Bool,
        isPackage: Bool = false,
        sourceEvidence: MediaCopyPathEvidence? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceRoot = sourceRoot
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.hasDestinationConflict = hasDestinationConflict
        self.isPackage = isPackage
        self.sourceEvidence = sourceEvidence
            ?? MediaCopyPathEvidence.capture(at: sourceURL, recursively: isPackage)
    }

    public var name: String {
        sourceURL.lastPathComponent
    }

    public var relativeDirectory: String? {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    public func markingDestinationConflict() -> Self {
        Self(
            id: id,
            sourceURL: sourceURL,
            sourceRoot: sourceRoot,
            destinationURL: destinationURL,
            relativePath: relativePath,
            fileSizeBytes: fileSizeBytes,
            hasDestinationConflict: true,
            isPackage: isPackage,
            sourceEvidence: sourceEvidence
        )
    }
}

public struct MediaDeleteCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let sourceRoot: URL
    public let relativePath: String
    public let fileSizeBytes: Int64

    public init(
        id: String,
        sourceURL: URL,
        sourceRoot: URL,
        relativePath: String,
        fileSizeBytes: Int64
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
    }

    public var name: String {
        sourceURL.lastPathComponent
    }

    public var relativeDirectory: String? {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}

public struct MediaFileInventoryRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let sourceRoot: URL
    public let relativePath: String
    public let normalizedFileName: String
    public let fileSizeBytes: Int64
    public let modifiedDate: Date?

    public init(
        id: String,
        sourceURL: URL,
        sourceRoot: URL,
        relativePath: String,
        normalizedFileName: String? = nil,
        fileSizeBytes: Int64,
        modifiedDate: Date?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        self.normalizedFileName =
            normalizedFileName ?? MediaFileNameFilter.normalizedFileName(sourceURL.lastPathComponent)
        self.fileSizeBytes = fileSizeBytes
        self.modifiedDate = modifiedDate
    }

    public var name: String {
        sourceURL.lastPathComponent
    }

    public var relativeDirectory: String? {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}

public struct MediaCopyPlan: Sendable {
    public let sourceRoot: URL
    public let destinationRoot: URL
    public let filter: MediaFileFilter
    public let selectedExtensions: Set<String>?
    public let fileNameFilter: MediaFileNameFilter
    public let candidates: [MediaCopyCandidate]
    public let relativeDirectories: [String]
    public let candidateCount: Int
    public let totalSizeBytes: Int64
    public let conflictCount: Int
    public let plannedDestinationPaths: [String]
    public let plannedDestinations: [MediaCopyPlannedDestination]
    public let plannedDirectoryPaths: [String]
    public let scannedAt: Date

    public init(
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>? = nil,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        candidates: [MediaCopyCandidate],
        relativeDirectories: [String] = [],
        candidateCount: Int? = nil,
        totalSizeBytes: Int64? = nil,
        conflictCount: Int? = nil,
        plannedDestinationPaths: [String]? = nil,
        plannedDestinations: [MediaCopyPlannedDestination]? = nil,
        plannedDirectoryPaths: [String]? = nil,
        scannedAt: Date
    ) {
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.filter = filter
        self.selectedExtensions = selectedExtensions
        self.fileNameFilter = fileNameFilter
        self.candidates = candidates
        self.relativeDirectories = relativeDirectories
        self.candidateCount = candidateCount ?? candidates.count
        self.totalSizeBytes = totalSizeBytes ?? candidates.reduce(0) { $0 + $1.fileSizeBytes }
        self.conflictCount = conflictCount ?? candidates.filter(\.hasDestinationConflict).count
        self.plannedDestinationPaths =
            plannedDestinationPaths ?? candidates.map { $0.destinationURL.standardizedFileURL.path }
        self.plannedDestinations = plannedDestinations
            ?? candidates.map {
                MediaCopyPlannedDestination(
                    path: $0.destinationURL.standardizedFileURL.path,
                    kind: $0.isPackage ? .package : .file
                )
            }
        self.plannedDirectoryPaths = plannedDirectoryPaths
            ?? relativeDirectories.map {
                destinationRoot.appendingPathComponent($0, isDirectory: true)
                    .standardizedFileURL.path
            }
        self.scannedAt = scannedAt
    }

    public var hasCopyableContent: Bool {
        candidateCount > 0 || !relativeDirectories.isEmpty
    }

    public var copyableWithoutOverwriteCount: Int {
        candidateCount - conflictCount
    }

    public var directoryCount: Int {
        relativeDirectories.count
    }
}

public struct MediaDeletePlan: Sendable {
    public let sourceRoots: [URL]
    public let filter: MediaFileFilter
    public let selectedExtensions: Set<String>
    public let fileNameFilter: MediaFileNameFilter
    public let candidates: [MediaDeleteCandidate]
    public let candidateCount: Int
    public let totalSizeBytes: Int64
    public let scannedAt: Date

    public init(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        candidates: [MediaDeleteCandidate],
        candidateCount: Int? = nil,
        totalSizeBytes: Int64? = nil,
        scannedAt: Date
    ) {
        self.sourceRoots = sourceRoots
        self.filter = filter
        self.selectedExtensions = selectedExtensions
        self.fileNameFilter = fileNameFilter
        self.candidates = candidates
        self.candidateCount = candidateCount ?? candidates.count
        self.totalSizeBytes = totalSizeBytes ?? candidates.reduce(0) { $0 + $1.fileSizeBytes }
        self.scannedAt = scannedAt
    }

    public var hasDeletableContent: Bool {
        candidateCount > 0
    }
}

public struct MediaCopyProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let copied: Int
    public let skippedExisting: Int
    public let failed: Int
    public let copiedBytes: Int64
    public let totalBytes: Int64
    public let startedAt: Date
    public let updatedAt: Date
    public let currentName: String?

    public init(
        completed: Int,
        total: Int,
        copied: Int,
        skippedExisting: Int,
        failed: Int,
        copiedBytes: Int64,
        totalBytes: Int64,
        startedAt: Date,
        updatedAt: Date,
        currentName: String?
    ) {
        self.completed = completed
        self.total = total
        self.copied = copied
        self.skippedExisting = skippedExisting
        self.failed = failed
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.currentName = currentName
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    public var bytesPerSecond: Double? {
        let elapsed = updatedAt.timeIntervalSince(startedAt)
        guard copiedBytes > 0, elapsed > 0 else { return nil }
        return Double(copiedBytes) / elapsed
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
    public var rejected: Bool
    public var stalePlan: Bool
    public var rollbackFailed: Bool
    public var recoveryPath: String?
    public var appliedDestinationEvidence: [String: MediaCopyPathEvidence]

    public init(
        total: Int = 0,
        copied: Int = 0,
        skippedExisting: Int = 0,
        failed: Int = 0,
        failedNames: [String] = [],
        createdDirectories: Int = 0,
        failedDirectories: Int = 0,
        failedDirectoryNames: [String] = [],
        cancelled: Bool = false,
        rejected: Bool = false,
        stalePlan: Bool = false,
        rollbackFailed: Bool = false,
        recoveryPath: String? = nil,
        appliedDestinationEvidence: [String: MediaCopyPathEvidence] = [:]
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
        self.rejected = rejected
        self.stalePlan = stalePlan
        self.rollbackFailed = rollbackFailed
        self.recoveryPath = recoveryPath
        self.appliedDestinationEvidence = appliedDestinationEvidence
    }
}

public enum MediaCopyPlanner {
    public static func scanFileInventory(
        sourceRoots: [URL]
    ) throws -> [MediaFileInventoryRecord] {
        var records: [MediaFileInventoryRecord] = []
        var seenPaths = Set<String>()
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for sourceRoot in sourceRoots {
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
                guard values?.isRegularFile == true else { continue }

                let standardizedPath = sourceURL.standardizedFileURL.path
                guard !seenPaths.contains(standardizedPath) else { continue }
                guard let relativeComponents = relativePathComponents(
                    for: sourceURL,
                    sourceRoot: sourceRoot
                ) else {
                    continue
                }

                records.append(
                    MediaFileInventoryRecord(
                        id: standardizedPath,
                        sourceURL: sourceURL,
                        sourceRoot: sourceRoot,
                        relativePath: relativeComponents.joined(separator: "/"),
                        normalizedFileName: MediaFileNameFilter.normalizedFileName(
                            sourceURL.lastPathComponent
                        ),
                        fileSizeBytes: values?.fileSize.map(Int64.init) ?? 0,
                        modifiedDate: values?.contentModificationDate
                    )
                )
                seenPaths.insert(standardizedPath)
            }
        }

        return records.sorted {
            $0.sourceURL.path.localizedCaseInsensitiveCompare($1.sourceURL.path)
                == .orderedAscending
        }
    }

    public static func buildDeletePlan(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        candidateLimit: Int? = nil
    ) throws -> MediaDeletePlan {
        let inventory = try scanFileInventory(sourceRoots: sourceRoots)
        return buildDeletePlan(
            sourceRoots: sourceRoots,
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter,
            candidateLimit: candidateLimit,
            inventory: inventory
        )
    }

    public static func buildDeletePlan(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        candidateLimit: Int? = nil,
        inventory: [MediaFileInventoryRecord]
    ) -> MediaDeletePlan {
        let sourceRootKeys = Set(sourceRoots.map { $0.standardizedFileURL.path })
        var candidates: [MediaDeleteCandidate] = []
        var candidateCount = 0
        var totalSizeBytes: Int64 = 0

        for record in inventory where sourceRootKeys.contains(record.sourceRoot.standardizedFileURL.path)
            && filter.matches(record.sourceURL, selectedExtensions: selectedExtensions)
            && fileNameFilter.matches(normalizedFileName: record.normalizedFileName)
        {
            candidateCount += 1
            totalSizeBytes += record.fileSizeBytes
            if candidateLimit.map({ candidates.count < $0 }) ?? true {
                candidates.append(
                    MediaDeleteCandidate(
                        id: record.id,
                        sourceURL: record.sourceURL,
                        sourceRoot: record.sourceRoot,
                        relativePath: record.relativePath,
                        fileSizeBytes: record.fileSizeBytes
                    )
                )
            }
        }

        return MediaDeletePlan(
            sourceRoots: sourceRoots,
            filter: filter,
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter,
            candidates: candidates,
            candidateCount: candidateCount,
            totalSizeBytes: totalSizeBytes,
            scannedAt: Date()
        )
    }

    public static func buildPlan(
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>? = nil,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter(),
        candidateLimit: Int? = nil
    ) throws -> MediaCopyPlan {
        var candidates: [MediaCopyCandidate] = []
        var relativeDirectories: [String] = []
        var candidateCount = 0
        var totalSizeBytes: Int64 = 0
        var conflictCount = 0
        var plannedDestinationPaths: [String] = []
        var plannedDestinations: [MediaCopyPlannedDestination] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isPackageKey,
            .fileSizeKey,
        ]

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

            if values?.isPackage == true {
                guard filter == .all,
                    fileNameFilter.matches(fileName: sourceURL.lastPathComponent),
                    let relativeComponents = relativePathComponents(
                        for: sourceURL,
                        sourceRoot: sourceRoot
                    )
                else {
                    continue
                }

                let destinationURL = appendingPathComponents(
                    relativeComponents,
                    to: destinationRoot
                )
                let relativePath = relativeComponents.joined(separator: "/")
                let destinationConflict = fileManager.fileExists(atPath: destinationURL.path)
                let packageSize = try recursiveFileSize(at: sourceURL)
                plannedDestinationPaths.append(destinationURL.standardizedFileURL.path)
                plannedDestinations.append(
                    MediaCopyPlannedDestination(
                        path: destinationURL.standardizedFileURL.path,
                        kind: .package
                    )
                )

                candidateCount += 1
                totalSizeBytes += packageSize
                if destinationConflict {
                    conflictCount += 1
                }
                if candidateLimit.map({ candidates.count < $0 }) ?? true {
                    candidates.append(
                        MediaCopyCandidate(
                            id: sourceURL.standardizedFileURL.path,
                            sourceURL: sourceURL,
                            sourceRoot: sourceRoot,
                            destinationURL: destinationURL,
                            relativePath: relativePath,
                            fileSizeBytes: packageSize,
                            hasDestinationConflict: destinationConflict,
                            isPackage: true
                        )
                    )
                }
                continue
            }

            if filter == .all, !fileNameFilter.isActive, values?.isDirectory == true,
                let relativeComponents = relativePathComponents(
                    for: sourceURL,
                    sourceRoot: sourceRoot
                )
            {
                relativeDirectories.append(relativeComponents.joined(separator: "/"))
                continue
            }

            guard values?.isRegularFile == true,
                filter.matches(sourceURL, selectedExtensions: selectedExtensions),
                fileNameFilter.matches(fileName: sourceURL.lastPathComponent)
            else {
                continue
            }

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
            plannedDestinationPaths.append(destinationURL.standardizedFileURL.path)
            plannedDestinations.append(
                MediaCopyPlannedDestination(
                    path: destinationURL.standardizedFileURL.path,
                    kind: .file
                )
            )

            candidateCount += 1
            totalSizeBytes += values?.fileSize.map(Int64.init) ?? 0
            if destinationConflict {
                conflictCount += 1
            }

            if candidateLimit.map({ candidates.count < $0 }) ?? true {
                candidates.append(
                    MediaCopyCandidate(
                        id: sourceURL.standardizedFileURL.path,
                        sourceURL: sourceURL,
                        sourceRoot: sourceRoot,
                        destinationURL: destinationURL,
                        relativePath: relativePath,
                        fileSizeBytes: values?.fileSize.map(Int64.init) ?? 0,
                        hasDestinationConflict: destinationConflict,
                        isPackage: false
                    )
                )
            }
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
            selectedExtensions: selectedExtensions,
            fileNameFilter: fileNameFilter,
            candidates: candidates,
            relativeDirectories: relativeDirectories,
            candidateCount: candidateCount,
            totalSizeBytes: totalSizeBytes,
            conflictCount: conflictCount,
            plannedDestinationPaths: plannedDestinationPaths,
            plannedDestinations: plannedDestinations,
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
                guard candidate.isPackage else { return .failed(candidate.relativePath) }
            }

            if destinationExists && conflictResolution == .skipExisting {
                return .skippedExisting
            }

            if candidate.isPackage {
                let tempURL = destinationDirectory.appendingPathComponent(
                    ".gphilcoder-\(UUID().uuidString).tmp-package",
                    isDirectory: true
                )
                temporaryURL = tempURL
                try fileManager.copyItem(at: candidate.sourceURL, to: tempURL)
                if destinationExists {
                    _ = try fileManager.replaceItemAt(
                        candidate.destinationURL,
                        withItemAt: tempURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: tempURL, to: candidate.destinationURL)
                }
            } else if destinationExists {
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

    private static func recursiveFileSize(at root: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += values?.fileSize.map(Int64.init) ?? 0
            }
        }
        return total
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
