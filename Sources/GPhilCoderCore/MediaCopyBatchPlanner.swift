import Foundation

public enum MediaCopyDestinationLayout: String, CaseIterable, Codable, Hashable, Sendable {
    case sourceFolders
    case mergeContents

    public var title: String {
        switch self {
        case .sourceFolders:
            "Source folders"
        case .mergeContents:
            "Merge contents"
        }
    }

    public var description: String {
        switch self {
        case .sourceFolders:
            "Place each selected source folder inside the destination."
        case .mergeContents:
            "Place each source folder's contents directly in the destination."
        }
    }

    public func resolvedDestinationRoot(for sourceRoot: URL, destinationRoot: URL) -> URL {
        guard self == .sourceFolders else { return destinationRoot }
        let sourceFolderName = sourceRoot.lastPathComponent
        guard !sourceFolderName.isEmpty else { return destinationRoot }
        return destinationRoot.appendingPathComponent(sourceFolderName, isDirectory: true)
    }
}

public struct MediaCopyBatchConfiguration: Hashable, Sendable {
    public let sourceRoots: [URL]
    public let destinationRoot: URL
    public let destinationLayout: MediaCopyDestinationLayout
    public let filter: MediaFileFilter
    public let selectedExtensions: Set<String>?
    public let fileNameFilter: MediaFileNameFilter

    public init(
        sourceRoots: [URL],
        destinationRoot: URL,
        destinationLayout: MediaCopyDestinationLayout = .sourceFolders,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>? = nil,
        fileNameFilter: MediaFileNameFilter = MediaFileNameFilter()
    ) {
        self.sourceRoots = sourceRoots
        self.destinationRoot = destinationRoot
        self.destinationLayout = destinationLayout
        self.filter = filter
        self.selectedExtensions = selectedExtensions
        self.fileNameFilter = fileNameFilter
    }
}

public struct MediaCopyBatchPlan: Sendable {
    public let configuration: MediaCopyBatchConfiguration
    public let sourcePlans: [MediaCopyPlan]
    public let candidates: [MediaCopyCandidate]
    public let candidateCount: Int
    public let totalSizeBytes: Int64
    public let conflictCount: Int
    public let copyableWithoutOverwriteCount: Int
    public let structuralConflictCount: Int
    public let destinationUsesCaseSensitiveNames: Bool
    public let reviewedSourceEvidence: [String: MediaCopyPathEvidence]
    public let reviewedDestinationEvidence: [String: MediaCopyPathEvidence]
    public let scannedAt: Date

    public init(
        configuration: MediaCopyBatchConfiguration,
        sourcePlans: [MediaCopyPlan],
        candidates: [MediaCopyCandidate]? = nil,
        scannedAt: Date = Date()
    ) {
        self.configuration = configuration
        self.sourcePlans = sourcePlans
        let destinationUsesCaseSensitiveNames =
            (try? configuration.destinationRoot.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames) ?? false
        let plannedCandidates = sourcePlans.flatMap(\.plannedDestinations)
        let candidatePaths = plannedCandidates.map(\.path)
        let directoryPaths = sourcePlans.flatMap(\.plannedDirectoryPaths)
        let destinationPathCounts = Dictionary(
            grouping: candidatePaths,
            by: { Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames) }
        )
            .mapValues(\.count)
        let duplicateKeys = Set(
            destinationPathCounts.compactMap { key, count in count > 1 ? key : nil }
        )
        let structuralCandidateKeys = Self.structuralCandidateKeys(
            plannedCandidates: plannedCandidates,
            directoryPaths: directoryPaths,
            destinationRoot: configuration.destinationRoot,
            caseSensitive: destinationUsesCaseSensitiveNames
        )
        let structuralDirectoryKeys = Self.structuralDirectoryKeys(
            directoryPaths: directoryPaths,
            candidatePaths: candidatePaths,
            destinationRoot: configuration.destinationRoot,
            caseSensitive: destinationUsesCaseSensitiveNames
        )
        let existingCandidateKeys = Set(
            candidatePaths.compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? Self.pathKey(path, caseSensitive: destinationUsesCaseSensitiveNames)
                    : nil
            }
        )
        let conflictingCandidateKeys = duplicateKeys
            .union(structuralCandidateKeys)
            .union(existingCandidateKeys)
        let visibleCandidates = candidates ?? sourcePlans.flatMap(\.candidates)
        let markedCandidates = visibleCandidates.map { candidate in
            conflictingCandidateKeys.contains(
                Self.pathKey(
                    candidate.destinationURL.standardizedFileURL.path,
                    caseSensitive: destinationUsesCaseSensitiveNames
                )
            )
                ? candidate.markingDestinationConflict()
                : candidate
        }
        let candidateCount = sourcePlans.reduce(0) { $0 + $1.candidateCount }
        let totalSizeBytes = sourcePlans.reduce(0) { $0 + $1.totalSizeBytes }
        let conflictCount = candidatePaths.filter {
            conflictingCandidateKeys.contains(
                Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames)
            )
        }.count + directoryPaths.filter {
            structuralDirectoryKeys.contains(
                Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames)
            )
        }.count
        let structuralConflictCount = candidatePaths.filter {
            structuralCandidateKeys.contains(
                Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames)
            )
        }.count + directoryPaths.filter {
            structuralDirectoryKeys.contains(
                Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames)
            )
        }.count
        let copyableWithoutOverwriteCount = Set(candidatePaths.map {
            Self.pathKey($0, caseSensitive: destinationUsesCaseSensitiveNames)
        }).reduce(0) { count, key in
            structuralCandidateKeys.contains(key)
                || existingCandidateKeys.contains(key)
                    ? count
                    : count + 1
        }
        let reviewedPaths = Self.reviewedDestinationPaths(
            candidatePaths: candidatePaths,
            directoryPaths: directoryPaths,
            destinationRoot: configuration.destinationRoot
        )
        let reviewedDestinationEvidence = Dictionary(
            uniqueKeysWithValues: reviewedPaths.map { path in
                let url = URL(fileURLWithPath: path)
                let evidence = MediaCopyPathEvidence.capture(at: url, recursively: true)
                return (path, evidence)
            }
        )
        let reviewedSourcePaths = Set(sourcePlans.flatMap { sourcePlan in
            [sourcePlan.sourceRoot.standardizedFileURL.path]
                + sourcePlan.relativeDirectories.map {
                    sourcePlan.sourceRoot.appendingPathComponent($0, isDirectory: true)
                        .standardizedFileURL.path
                }
        })
        let reviewedSourceEvidence = Dictionary(
            uniqueKeysWithValues: reviewedSourcePaths.map { path in
                (path, MediaCopyPathEvidence.capture(at: URL(fileURLWithPath: path)))
            }
        )
        self.candidates = markedCandidates
        self.candidateCount = candidateCount
        self.totalSizeBytes = totalSizeBytes
        self.conflictCount = conflictCount
        self.copyableWithoutOverwriteCount = copyableWithoutOverwriteCount
        self.structuralConflictCount = structuralConflictCount
        self.destinationUsesCaseSensitiveNames = destinationUsesCaseSensitiveNames
        self.reviewedSourceEvidence = reviewedSourceEvidence
        self.reviewedDestinationEvidence = reviewedDestinationEvidence
        self.scannedAt = scannedAt
    }

    public var sourceRoots: [URL] { configuration.sourceRoots }
    public var destinationRoot: URL { configuration.destinationRoot }
    public var destinationLayout: MediaCopyDestinationLayout { configuration.destinationLayout }
    public var filter: MediaFileFilter { configuration.filter }
    public var selectedExtensions: Set<String>? { configuration.selectedExtensions }
    public var fileNameFilter: MediaFileNameFilter { configuration.fileNameFilter }
    public var hasCopyableContent: Bool { sourcePlans.contains(where: \.hasCopyableContent) }
    public var canExecute: Bool { structuralConflictCount == 0 }
    public var directoryCount: Int { sourcePlans.reduce(0) { $0 + $1.directoryCount } }

    public func matchesReviewedFilesystemEvidence() -> Bool {
        let completeSourceEvidence = sourcePlans.allSatisfy { sourcePlan in
            sourcePlan.candidates.count == sourcePlan.candidateCount
                && sourcePlan.candidates.allSatisfy { candidate in
                    MediaCopyPathEvidence.capture(
                        at: candidate.sourceURL,
                        recursively: candidate.isPackage
                    ) == candidate.sourceEvidence
                }
        }
        guard completeSourceEvidence else { return false }
        guard reviewedSourceEvidence.allSatisfy({ path, evidence in
            MediaCopyPathEvidence.capture(at: URL(fileURLWithPath: path)) == evidence
        }) else { return false }
        return reviewedDestinationEvidence.allSatisfy { path, evidence in
            MediaCopyPathEvidence.capture(
                at: URL(fileURLWithPath: path),
                recursively: evidence.kind == .package
            ) == evidence
        }
    }

    public func destinationEvidenceKey(for url: URL) -> String {
        Self.pathKey(
            url.standardizedFileURL.path,
            caseSensitive: destinationUsesCaseSensitiveNames
        )
    }

    public func reviewedDestinationEvidence(at url: URL) -> MediaCopyPathEvidence? {
        let requestedKey = destinationEvidenceKey(for: url)
        return reviewedDestinationEvidence.first { path, _ in
            Self.pathKey(path, caseSensitive: destinationUsesCaseSensitiveNames) == requestedKey
        }?.value
    }

    public func rebasingDestinationEvidence(
        forOwnedChanges appliedEvidence: [String: MediaCopyPathEvidence]
    ) -> Self {
        guard !appliedEvidence.isEmpty else { return self }
        let appliedByKey = Dictionary(
            appliedEvidence.map {
                (
                    Self.pathKey($0.key, caseSensitive: destinationUsesCaseSensitiveNames),
                    $0.value
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        var rebasedEvidence = reviewedDestinationEvidence
        for path in reviewedDestinationEvidence.keys {
            let key = Self.pathKey(path, caseSensitive: destinationUsesCaseSensitiveNames)
            if let evidence = appliedByKey[key] {
                rebasedEvidence[path] = evidence
            }
        }
        return Self(copying: self, reviewedDestinationEvidence: rebasedEvidence)
    }

    private init(
        copying plan: Self,
        reviewedDestinationEvidence: [String: MediaCopyPathEvidence]
    ) {
        configuration = plan.configuration
        sourcePlans = plan.sourcePlans
        candidates = plan.candidates
        candidateCount = plan.candidateCount
        totalSizeBytes = plan.totalSizeBytes
        conflictCount = plan.conflictCount
        copyableWithoutOverwriteCount = plan.copyableWithoutOverwriteCount
        structuralConflictCount = plan.structuralConflictCount
        destinationUsesCaseSensitiveNames = plan.destinationUsesCaseSensitiveNames
        reviewedSourceEvidence = plan.reviewedSourceEvidence
        self.reviewedDestinationEvidence = reviewedDestinationEvidence
        scannedAt = plan.scannedAt
    }

    private static func structuralCandidateKeys(
        plannedCandidates: [MediaCopyPlannedDestination],
        directoryPaths: [String],
        destinationRoot: URL,
        caseSensitive: Bool
    ) -> Set<String> {
        let candidateGroups = Dictionary(
            grouping: plannedCandidates,
            by: { pathKey($0.path, caseSensitive: caseSensitive) }
        )
        let directoryKeys = directoryPaths.map { pathKey($0, caseSensitive: caseSensitive) }
        var conflicts = Set<String>()
        for (candidateKey, items) in candidateGroups {
            let firstPath = items[0].path
            if directoryKeys.contains(where: {
                $0 == candidateKey || $0.hasPrefix(candidateKey + "/")
            }) || hasBlockingAncestor(onDiskFor: firstPath, destinationRoot: destinationRoot)
                || items.contains(where: existingTypeMismatch)
                || Set(items.map(\.kind)).count > 1
            {
                conflicts.insert(candidateKey)
            }
            for otherKey in candidateGroups.keys where otherKey != candidateKey {
                if otherKey.hasPrefix(candidateKey + "/") {
                    conflicts.insert(candidateKey)
                    conflicts.insert(otherKey)
                }
            }
        }
        return conflicts
    }

    private static func structuralDirectoryKeys(
        directoryPaths: [String],
        candidatePaths: [String],
        destinationRoot: URL,
        caseSensitive: Bool
    ) -> Set<String> {
        let candidateKeys = candidatePaths.map { pathKey($0, caseSensitive: caseSensitive) }
        return Set(directoryPaths.compactMap { directoryPath in
            let directoryKey = pathKey(directoryPath, caseSensitive: caseSensitive)
            let isStructural = candidateKeys.contains(where: {
                directoryKey == $0 || directoryKey.hasPrefix($0 + "/")
            }) || pathIsNonDirectoryOrPackage(directoryPath)
                || hasBlockingAncestor(onDiskFor: directoryPath, destinationRoot: destinationRoot)
            return isStructural ? directoryKey : nil
        })
    }

    private static func existingTypeMismatch(_ item: MediaCopyPlannedDestination) -> Bool {
        let evidence = MediaCopyPathEvidence.capture(at: URL(fileURLWithPath: item.path))
        return switch (item.kind, evidence.kind) {
        case (_, .missing):
            false
        case (.file, .regularFile), (.package, .package):
            false
        default:
            true
        }
    }

    private static func hasBlockingAncestor(
        onDiskFor path: String,
        destinationRoot: URL
    ) -> Bool {
        let rootPath = destinationRoot.standardizedFileURL.path
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != rootPath, url.path.hasPrefix(rootPath + "/") {
            if pathIsNonDirectoryOrPackage(url.path) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func pathIsNonDirectoryOrPackage(_ path: String) -> Bool {
        let kind = MediaCopyPathEvidence.capture(at: URL(fileURLWithPath: path)).kind
        return kind != .missing && kind != .directory
    }

    private static func reviewedDestinationPaths(
        candidatePaths: [String],
        directoryPaths: [String],
        destinationRoot: URL
    ) -> Set<String> {
        let rootPath = destinationRoot.standardizedFileURL.path
        var paths: Set<String> = []
        for path in candidatePaths + directoryPaths {
            var url = URL(fileURLWithPath: path).standardizedFileURL
            while url.path != rootPath, url.path.hasPrefix(rootPath + "/") {
                paths.insert(url.path)
                url.deleteLastPathComponent()
            }
        }
        return paths
    }

    private static func pathKey(_ path: String, caseSensitive: Bool) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return caseSensitive
            ? standardized.precomposedStringWithCanonicalMapping
            : standardized.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}

public enum MediaCopyBatchPlanner {
    public static func buildPlan(
        configuration: MediaCopyBatchConfiguration,
        candidateLimit: Int? = nil
    ) throws -> MediaCopyBatchPlan {
        let perSourceLimit = candidateLimit
        let sourcePlans = try configuration.sourceRoots.map { sourceRoot in
            try Task.checkCancellation()
            return try MediaCopyPlanner.buildPlan(
                sourceRoot: sourceRoot,
                destinationRoot: configuration.destinationLayout.resolvedDestinationRoot(
                    for: sourceRoot,
                    destinationRoot: configuration.destinationRoot
                ),
                filter: configuration.filter,
                selectedExtensions: configuration.selectedExtensions,
                fileNameFilter: configuration.fileNameFilter,
                candidateLimit: perSourceLimit
            )
        }

        let visibleCandidates = candidateLimit.map {
            fairCandidates(from: sourcePlans, limit: $0)
        } ?? sourcePlans.flatMap(\.candidates)

        return MediaCopyBatchPlan(
            configuration: configuration,
            sourcePlans: sourcePlans,
            candidates: visibleCandidates
        )
    }

    public static func buildQueueReviewPlans(
        from plans: [MediaCopyBatchPlan]
    ) -> [MediaCopyBatchPlan] {
        var groups: [[MediaCopyBatchPlan]] = []
        for plan in plans {
            let matchingIndices = groups.indices.filter { groupIndex in
                groups[groupIndex].contains { rootsOverlap($0.destinationRoot, plan.destinationRoot) }
            }
            guard let firstMatchingIndex = matchingIndices.first else {
                groups.append([plan])
                continue
            }

            var mergedGroup = groups[firstMatchingIndex] + [plan]
            for groupIndex in matchingIndices.dropFirst().reversed() {
                mergedGroup.append(contentsOf: groups.remove(at: groupIndex))
            }
            groups[firstMatchingIndex] = mergedGroup
        }

        return groups.map { group in
            guard group.count > 1 else { return group[0] }
            let reviewRoot = group.dropFirst().reduce(group[0].destinationRoot) { root, plan in
                plan.destinationRoot.standardizedFileURL.pathComponents.count
                    < root.standardizedFileURL.pathComponents.count
                    ? plan.destinationRoot
                    : root
            }
            return MediaCopyBatchPlan(
                configuration: MediaCopyBatchConfiguration(
                    sourceRoots: group.flatMap(\.sourceRoots),
                    destinationRoot: reviewRoot,
                    destinationLayout: .mergeContents,
                    filter: .all
                ),
                sourcePlans: group.flatMap(\.sourcePlans)
            )
        }
    }

    private static func rootsOverlap(_ first: URL, _ second: URL) -> Bool {
        let firstPath = overlapKey(first)
        let secondPath = overlapKey(second)
        return firstPath == secondPath
            || firstPath.hasPrefix(secondPath + "/")
            || secondPath.hasPrefix(firstPath + "/")
    }

    private static func overlapKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func fairCandidates(
        from plans: [MediaCopyPlan],
        limit: Int
    ) -> [MediaCopyCandidate] {
        guard limit > 0 else { return [] }
        var result: [MediaCopyCandidate] = []
        var nextIndices = Array(repeating: 0, count: plans.count)

        while result.count < limit {
            var addedCandidate = false
            for planIndex in plans.indices where result.count < limit {
                let candidateIndex = nextIndices[planIndex]
                guard candidateIndex < plans[planIndex].candidates.count else { continue }
                result.append(plans[planIndex].candidates[candidateIndex])
                nextIndices[planIndex] += 1
                addedCandidate = true
            }
            guard addedCandidate else { break }
        }

        return result
    }
}
