import Foundation

public enum MediaRenameOperation: String, CaseIterable, Codable, Identifiable, Sendable {
    case pattern
    case autoIndex
    case replaceText
    case addText
    case changeCase
    case cleanUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pattern:
            "Pattern"
        case .autoIndex:
            "Auto Index"
        case .replaceText:
            "Replace"
        case .addText:
            "Add Text"
        case .changeCase:
            "Case"
        case .cleanUp:
            "Clean"
        }
    }
}

public enum MediaRenameTextPlacement: String, CaseIterable, Codable, Identifiable, Sendable {
    case prefix
    case suffix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prefix:
            "Before name"
        case .suffix:
            "After name"
        }
    }
}

public enum MediaRenameCaseStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case lowercase
    case uppercase
    case titleCase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lowercase:
            "lowercase"
        case .uppercase:
            "UPPERCASE"
        case .titleCase:
            "Capitalize"
        }
    }
}

public enum MediaRenameSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case name
    case modifiedDate
    case size

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name:
            "Name"
        case .modifiedDate:
            "Modified"
        case .size:
            "Size"
        }
    }
}

public enum MediaRenameValidationState: String, Codable, Hashable, Sendable {
    case ready
    case unchanged
    case duplicate
    case conflict
    case invalid

    public var title: String {
        switch self {
        case .ready:
            "Ready"
        case .unchanged:
            "Unchanged"
        case .duplicate:
            "Duplicate"
        case .conflict:
            "Exists"
        case .invalid:
            "Invalid"
        }
    }
}

public struct MediaRenameSettings: Codable, Equatable, Sendable {
    public var operation: MediaRenameOperation
    public var pattern: String
    public var findText: String
    public var replacementText: String
    public var isCaseSensitive: Bool
    public var addedText: String
    public var textPlacement: MediaRenameTextPlacement
    public var caseStyle: MediaRenameCaseStyle
    public var sort: MediaRenameSort
    public var startIndex: Int
    public var indexStep: Int
    public var indexPadding: Int

    public init(
        operation: MediaRenameOperation = .pattern,
        pattern: String = "{name}",
        findText: String = "",
        replacementText: String = "",
        isCaseSensitive: Bool = false,
        addedText: String = "",
        textPlacement: MediaRenameTextPlacement = .suffix,
        caseStyle: MediaRenameCaseStyle = .titleCase,
        sort: MediaRenameSort = .name,
        startIndex: Int = 1,
        indexStep: Int = 1,
        indexPadding: Int = 2
    ) {
        self.operation = operation
        self.pattern = pattern
        self.findText = findText
        self.replacementText = replacementText
        self.isCaseSensitive = isCaseSensitive
        self.addedText = addedText
        self.textPlacement = textPlacement
        self.caseStyle = caseStyle
        self.sort = sort
        self.startIndex = startIndex
        self.indexStep = indexStep
        self.indexPadding = indexPadding
    }
}

public struct MediaRenameItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let targetURL: URL
    public let sourceRoot: URL
    public let relativePath: String
    public let originalName: String
    public let newName: String
    public let fileSizeBytes: Int64
    public let state: MediaRenameValidationState
    public let message: String

    public init(
        id: String,
        sourceURL: URL,
        targetURL: URL,
        sourceRoot: URL,
        relativePath: String,
        originalName: String,
        newName: String,
        fileSizeBytes: Int64,
        state: MediaRenameValidationState,
        message: String
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        self.originalName = originalName
        self.newName = newName
        self.fileSizeBytes = fileSizeBytes
        self.state = state
        self.message = message
    }

    public var relativeDirectory: String? {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}

public struct MediaRenamePlan: Sendable {
    public let sourceRoots: [URL]
    public let filter: MediaFileFilter
    public let selectedExtensions: Set<String>?
    public let settings: MediaRenameSettings
    public let items: [MediaRenameItem]
    public let scannedAt: Date

    public init(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>?,
        settings: MediaRenameSettings,
        items: [MediaRenameItem],
        scannedAt: Date
    ) {
        self.sourceRoots = sourceRoots
        self.filter = filter
        self.selectedExtensions = selectedExtensions
        self.settings = settings
        self.items = items
        self.scannedAt = scannedAt
    }

    public var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSizeBytes }
    }

    public var readyItems: [MediaRenameItem] {
        items.filter { $0.state == .ready }
    }

    public var readyCount: Int {
        readyItems.count
    }

    public var blockedCount: Int {
        items.filter { $0.state == .duplicate || $0.state == .conflict || $0.state == .invalid }.count
    }

    public var unchangedCount: Int {
        items.filter { $0.state == .unchanged }.count
    }

    public var hasRenameContent: Bool {
        !items.isEmpty
    }
}

extension MediaCopyPlanner {
    public static func buildRenamePlan(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>?,
        settings: MediaRenameSettings
    ) throws -> MediaRenamePlan {
        let inventory = try MediaCopyPlanner.scanFileInventory(sourceRoots: sourceRoots)
        return buildRenamePlan(
            sourceRoots: sourceRoots,
            filter: filter,
            selectedExtensions: selectedExtensions,
            settings: settings,
            inventory: inventory
        )
    }

    public static func buildRenamePlan(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>?,
        settings: MediaRenameSettings,
        inventory: [MediaFileInventoryRecord]
    ) -> MediaRenamePlan {
        let sourceRootKeys = Set(sourceRoots.map { $0.standardizedFileURL.path })
        let allKnownTargetKeys = Set(inventory.map { $0.sourceURL.standardizedFileURL.path.lowercased() })
        let candidates = inventory.compactMap { record -> RenameScanCandidate? in
            guard sourceRootKeys.contains(record.sourceRoot.standardizedFileURL.path),
                filter.matches(record.sourceURL, selectedExtensions: selectedExtensions)
            else {
                return nil
            }

            return RenameScanCandidate(
                sourceURL: record.sourceURL,
                sourceRoot: record.sourceRoot,
                relativePath: record.relativePath,
                fileSizeBytes: record.fileSizeBytes,
                modifiedDate: record.modifiedDate
            )
        }
        let items = buildRenameItems(
            candidates: candidates,
            settings: settings,
            knownTargetKeys: allKnownTargetKeys
        )

        return MediaRenamePlan(
            sourceRoots: sourceRoots,
            filter: filter,
            selectedExtensions: selectedExtensions,
            settings: settings,
            items: items,
            scannedAt: Date()
        )
    }

    private static func buildRenameItems(
        candidates: [RenameScanCandidate],
        settings: MediaRenameSettings,
        knownTargetKeys: Set<String>
    ) -> [MediaRenameItem] {
        let sortedCandidates = sortedRenameCandidates(candidates, by: settings.sort)
        let proposedItems = sortedCandidates.enumerated().map { index, candidate in
            proposedRenameItem(
                for: candidate,
                settings: settings,
                itemIndex: index,
                knownTargetKeys: knownTargetKeys
            )
        }
        let duplicateKeys = Set(
            Dictionary(grouping: proposedItems.filter { $0.state == .ready }, by: \.targetKey)
                .filter { $0.value.count > 1 }
                .keys
        )
        return proposedItems.map { proposed in
            let state: MediaRenameValidationState
            let message: String

            if proposed.state != .ready {
                state = proposed.state
                message = proposed.message
            } else if duplicateKeys.contains(proposed.targetKey) {
                state = .duplicate
                message = "Another file in this batch has the same target name."
            } else {
                state = .ready
                message = "Ready to rename."
            }

            return MediaRenameItem(
                id: proposed.sourceURL.standardizedFileURL.path,
                sourceURL: proposed.sourceURL,
                targetURL: proposed.targetURL,
                sourceRoot: proposed.sourceRoot,
                relativePath: proposed.relativePath,
                originalName: proposed.originalName,
                newName: proposed.newName,
                fileSizeBytes: proposed.fileSizeBytes,
                state: state,
                message: message
            )
        }
    }

    private struct RenameScanCandidate {
        let sourceURL: URL
        let sourceRoot: URL
        let relativePath: String
        let fileSizeBytes: Int64
        let modifiedDate: Date?
    }

    private struct ProposedRenameItem {
        let sourceURL: URL
        let targetURL: URL
        let sourceRoot: URL
        let relativePath: String
        let originalName: String
        let newName: String
        let fileSizeBytes: Int64
        let targetKey: String
        let state: MediaRenameValidationState
        let message: String
    }

    private static func scanRenameCandidates(
        sourceRoots: [URL],
        filter: MediaFileFilter,
        selectedExtensions: Set<String>?
    ) throws -> [RenameScanCandidate] {
        var candidates: [RenameScanCandidate] = []
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
                guard values?.isRegularFile == true,
                    filter.matches(sourceURL, selectedExtensions: selectedExtensions)
                else {
                    continue
                }

                let standardizedPath = sourceURL.standardizedFileURL.path
                guard !seenPaths.contains(standardizedPath) else { continue }
                guard let relativeComponents = relativePathComponents(
                    for: sourceURL,
                    sourceRoot: sourceRoot
                ) else {
                    continue
                }

                candidates.append(
                    RenameScanCandidate(
                        sourceURL: sourceURL,
                        sourceRoot: sourceRoot,
                        relativePath: relativeComponents.joined(separator: "/"),
                        fileSizeBytes: values?.fileSize.map(Int64.init) ?? 0,
                        modifiedDate: values?.contentModificationDate
                    )
                )
                seenPaths.insert(standardizedPath)
            }
        }

        return candidates
    }

    private static func sortedRenameCandidates(
        _ candidates: [RenameScanCandidate],
        by sort: MediaRenameSort
    ) -> [RenameScanCandidate] {
        candidates.sorted { first, second in
            switch sort {
            case .name:
                return first.sourceURL.path.localizedStandardCompare(second.sourceURL.path)
                    == .orderedAscending
            case .modifiedDate:
                if first.modifiedDate == second.modifiedDate {
                    return first.sourceURL.path.localizedStandardCompare(second.sourceURL.path)
                        == .orderedAscending
                }
                return (first.modifiedDate ?? .distantPast) < (second.modifiedDate ?? .distantPast)
            case .size:
                if first.fileSizeBytes == second.fileSizeBytes {
                    return first.sourceURL.path.localizedStandardCompare(second.sourceURL.path)
                        == .orderedAscending
                }
                return first.fileSizeBytes < second.fileSizeBytes
            }
        }
    }

    private static func proposedRenameItem(
        for candidate: RenameScanCandidate,
        settings: MediaRenameSettings,
        itemIndex: Int,
        knownTargetKeys: Set<String>
    ) -> ProposedRenameItem {
        let originalName = candidate.sourceURL.lastPathComponent
        let baseName = candidate.sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = candidate.sourceURL.pathExtension
        let parentName = candidate.sourceURL.deletingLastPathComponent().lastPathComponent
        let index = settings.startIndex + (itemIndex * max(1, settings.indexStep))
        let indexText = paddedIndex(index, width: settings.indexPadding)
        let dateText = formattedTemplateDate(candidate.modifiedDate)
        let proposedBaseName = sanitizedFileName(
            baseNameAfterRename(
                baseName: baseName,
                parentName: parentName,
                indexText: indexText,
                dateText: dateText,
                settings: settings
            )
        )
        let newName = fileExtension.isEmpty ? proposedBaseName : "\(proposedBaseName).\(fileExtension)"
        let targetURL = candidate.sourceURL.deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: false)
        let sourceKey = candidate.sourceURL.standardizedFileURL.path.lowercased()
        let targetKey = targetURL.standardizedFileURL.path.lowercased()

        let state: MediaRenameValidationState
        let message: String
        if proposedBaseName.isEmpty || newName == ".\(fileExtension)" {
            state = .invalid
            message = "New name is empty."
        } else if targetKey == sourceKey && newName == originalName {
            state = .unchanged
            message = "No change."
        } else if knownTargetKeys.contains(targetKey), targetKey != sourceKey {
            state = .conflict
            message = "A file already exists at the target name."
        } else {
            state = .ready
            message = "Ready to rename."
        }

        return ProposedRenameItem(
            sourceURL: candidate.sourceURL,
            targetURL: targetURL,
            sourceRoot: candidate.sourceRoot,
            relativePath: candidate.relativePath,
            originalName: originalName,
            newName: newName,
            fileSizeBytes: candidate.fileSizeBytes,
            targetKey: targetKey,
            state: state,
            message: message
        )
    }

    private static func baseNameAfterRename(
        baseName: String,
        parentName: String,
        indexText: String,
        dateText: String,
        settings: MediaRenameSettings
    ) -> String {
        switch settings.operation {
        case .pattern:
            return renderTemplate(
                settings.pattern,
                baseName: baseName,
                parentName: parentName,
                indexText: indexText,
                dateText: dateText
            )
        case .autoIndex:
            return indexText
        case .replaceText:
            return replaceText(
                in: baseName,
                findText: settings.findText,
                replacementText: settings.replacementText,
                isCaseSensitive: settings.isCaseSensitive
            )
        case .addText:
            let text = renderTemplate(
                settings.addedText,
                baseName: baseName,
                parentName: parentName,
                indexText: indexText,
                dateText: dateText
            )
            switch settings.textPlacement {
            case .prefix:
                return text + baseName
            case .suffix:
                return baseName + text
            }
        case .changeCase:
            switch settings.caseStyle {
            case .lowercase:
                return baseName.lowercased()
            case .uppercase:
                return baseName.uppercased()
            case .titleCase:
                return baseName.localizedCapitalized
            }
        case .cleanUp:
            return cleanFileName(baseName)
        }
    }

    private static func renderTemplate(
        _ template: String,
        baseName: String,
        parentName: String,
        indexText: String,
        dateText: String
    ) -> String {
        template
            .replacingOccurrences(of: "{name}", with: baseName)
            .replacingOccurrences(of: "{index}", with: indexText)
            .replacingOccurrences(of: "{parent}", with: parentName)
            .replacingOccurrences(of: "{date}", with: dateText)
    }

    private static func formattedTemplateDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func replaceText(
        in source: String,
        findText: String,
        replacementText: String,
        isCaseSensitive: Bool
    ) -> String {
        guard !findText.isEmpty else { return source }
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        return source.replacingOccurrences(of: findText, with: replacementText, options: options)
    }

    private static func cleanFileName(_ source: String) -> String {
        source
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sanitizedFileName(_ source: String) -> String {
        source
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paddedIndex(_ value: Int, width: Int) -> String {
        let safeWidth = max(1, min(width, 8))
        return String(format: "%0\(safeWidth)d", value)
    }
}
