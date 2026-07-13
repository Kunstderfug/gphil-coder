import Foundation

public enum FolderSyncOperationKind: String, Codable, Sendable {
    case createDirectory
    case copyNew
    case copyUpdated
    case deleteFile
    case deleteDirectory
}

public enum FolderSyncOperationResult: Equatable, Sendable {
    case applied
    case skippedExisting
    case failed(String)
}

public struct FolderSyncFileEvidence: Hashable, Codable, Sendable {
    public let isDirectory: Bool
    public let fileSizeBytes: Int64
    public let modificationDate: Date?
    public let descendantCount: Int
    public let contentSignature: UInt64

    public init(
        isDirectory: Bool,
        fileSizeBytes: Int64,
        modificationDate: Date?,
        descendantCount: Int = 0,
        contentSignature: UInt64
    ) {
        self.isDirectory = isDirectory
        self.fileSizeBytes = fileSizeBytes
        self.modificationDate = modificationDate
        self.descendantCount = descendantCount
        self.contentSignature = contentSignature
    }
}

public struct FolderSyncOperation: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: FolderSyncOperationKind
    public let sourceURL: URL?
    public let destinationURL: URL
    public let relativePath: String
    public let fileSizeBytes: Int64
    public let sourceEvidence: FolderSyncFileEvidence?
    public let destinationEvidence: FolderSyncFileEvidence?

    public init(
        kind: FolderSyncOperationKind,
        sourceURL: URL?,
        destinationURL: URL,
        relativePath: String,
        fileSizeBytes: Int64 = 0,
        sourceEvidence: FolderSyncFileEvidence? = nil,
        destinationEvidence: FolderSyncFileEvidence? = nil
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.sourceEvidence = sourceEvidence
        self.destinationEvidence = destinationEvidence
        self.id = "\(kind.rawValue):\(relativePath)"
    }
}

public struct FolderSyncPlan: Sendable {
    public let originRoot: URL
    public let destinationRoot: URL
    public let operations: [FolderSyncOperation]
    public let operationCount: Int
    public let copyCount: Int
    public let updatedCount: Int
    public let createdDirectoryCount: Int
    public let deletedFileCount: Int
    public let deletedDirectoryCount: Int
    public let totalCopyBytes: Int64
    public let totalDeleteBytes: Int64
    public let scannedAt: Date

    public var hasWork: Bool {
        operationCount > 0
    }

    public var deleteCount: Int {
        deletedFileCount + deletedDirectoryCount
    }
}

public enum FolderSyncPlanner {
    public static func buildPlan(
        originRoot: URL,
        destinationRoot: URL,
        syncDeletes: Bool = false,
        includedFileExtensions: Set<String>? = nil,
        operationLimit: Int? = nil
    ) throws -> FolderSyncPlan {
        let normalizedIncludedExtensions = includedFileExtensions.map(normalizedExtensions)
        let originInventory = try inventory(
            at: originRoot,
            includedFileExtensions: normalizedIncludedExtensions
        )
        let destinationInventory = try inventory(
            at: destinationRoot,
            includedFileExtensions: normalizedIncludedExtensions
        )
        var operations: [FolderSyncOperation] = []
        var operationCount = 0
        var copyCount = 0
        var updatedCount = 0
        var createdDirectoryCount = 0
        var deletedFileCount = 0
        var deletedDirectoryCount = 0
        var totalCopyBytes: Int64 = 0
        var totalDeleteBytes: Int64 = 0

        func append(_ operation: FolderSyncOperation) {
            operationCount += 1
            switch operation.kind {
            case .createDirectory:
                createdDirectoryCount += 1
            case .copyNew:
                copyCount += 1
                totalCopyBytes += operation.fileSizeBytes
            case .copyUpdated:
                copyCount += 1
                updatedCount += 1
                totalCopyBytes += operation.fileSizeBytes
            case .deleteFile:
                deletedFileCount += 1
                totalDeleteBytes += operation.fileSizeBytes
            case .deleteDirectory:
                deletedDirectoryCount += 1
                totalDeleteBytes += operation.fileSizeBytes
            }

            if operationLimit.map({ operations.count < $0 }) ?? true {
                operations.append(operation)
            }
        }

        let originDirectoryPaths = originInventory.directories.keys.sorted(by: localizedPathSort)
        for relativePath in originDirectoryPaths
        where destinationInventory.directories[relativePath] == nil {
            let destinationConflict = destinationInventory.files[relativePath]
            append(
                FolderSyncOperation(
                    kind: .createDirectory,
                    sourceURL: originInventory.directories[relativePath]?.url,
                    destinationURL: destinationRoot.appendingPathComponent(relativePath, isDirectory: true),
                    relativePath: relativePath,
                    sourceEvidence: originInventory.directories[relativePath]?.evidence,
                    destinationEvidence: destinationConflict?.evidence
                )
            )
        }

        let originFilePaths = originInventory.files.keys.sorted(by: localizedPathSort)
        for relativePath in originFilePaths {
            guard let sourceFile = originInventory.files[relativePath] else { continue }
            let destinationURL = destinationRoot.appendingPathComponent(relativePath, isDirectory: false)

            guard let destinationFile = destinationInventory.files[relativePath] else {
                let destinationConflict = destinationInventory.directories[relativePath]
                append(
                    FolderSyncOperation(
                        kind: .copyNew,
                        sourceURL: sourceFile.url,
                        destinationURL: destinationURL,
                        relativePath: relativePath,
                        fileSizeBytes: sourceFile.fileSizeBytes,
                        sourceEvidence: sourceFile.evidence,
                        destinationEvidence: destinationConflict?.evidence
                    )
                )
                continue
            }

            if shouldCopy(source: sourceFile, destination: destinationFile) {
                append(
                    FolderSyncOperation(
                        kind: .copyUpdated,
                        sourceURL: sourceFile.url,
                        destinationURL: destinationURL,
                        relativePath: relativePath,
                        fileSizeBytes: sourceFile.fileSizeBytes,
                        sourceEvidence: sourceFile.evidence,
                        destinationEvidence: destinationFile.evidence
                    )
                )
            }
        }

        if syncDeletes {
            let fileOverDirectoryConflictPrefixes = destinationInventory.directories.keys
                .filter { originInventory.files[$0] != nil }
            let destinationDirectoryPaths = destinationInventory.directories.keys
                .filter { path in
                    originInventory.directories[path] == nil
                        && originInventory.files[path] == nil
                        && !fileOverDirectoryConflictPrefixes.contains(where: { conflictPath in
                            path == conflictPath || isPath(path, below: conflictPath)
                        })
                }
                .sorted { left, right in
                    let leftDepth = left.split(separator: "/").count
                    let rightDepth = right.split(separator: "/").count
                    guard leftDepth == rightDepth else { return leftDepth < rightDepth }
                    return localizedPathSort(left, right)
                }
            var deletedDirectoryPrefixes: [String] = []
            if normalizedIncludedExtensions == nil {
                for relativePath in destinationDirectoryPaths {
                    guard !deletedDirectoryPrefixes.contains(where: { isPath(relativePath, below: $0) })
                    else { continue }
                    deletedDirectoryPrefixes.append(relativePath)
                }
            }

            let destinationFilePaths = destinationInventory.files.keys
                .filter { path in
                    originInventory.files[path] == nil
                        && originInventory.directories[path] == nil
                        && !fileOverDirectoryConflictPrefixes.contains(where: { conflictPath in
                            path == conflictPath || isPath(path, below: conflictPath)
                        })
                }
                .filter { path in
                    !deletedDirectoryPrefixes.contains(where: { isPath(path, below: $0) })
                }
                .sorted(by: localizedPathSort)
            for relativePath in destinationFilePaths {
                guard let destinationFile = destinationInventory.files[relativePath] else { continue }
                append(
                    FolderSyncOperation(
                        kind: .deleteFile,
                        sourceURL: nil,
                        destinationURL: destinationFile.url,
                        relativePath: relativePath,
                        fileSizeBytes: destinationFile.fileSizeBytes,
                        destinationEvidence: destinationFile.evidence
                    )
                )
            }

            for relativePath in deletedDirectoryPrefixes.sorted(by: deepestPathSort) {
                guard let destinationDirectory = destinationInventory.directories[relativePath] else { continue }
                append(
                    FolderSyncOperation(
                        kind: .deleteDirectory,
                        sourceURL: nil,
                        destinationURL: destinationDirectory.url,
                        relativePath: relativePath,
                        fileSizeBytes: destinationDirectory.fileSizeBytes,
                        destinationEvidence: destinationDirectory.evidence
                    )
                )
            }
        }

        operations.sort(by: operationSort)

        return FolderSyncPlan(
            originRoot: originRoot,
            destinationRoot: destinationRoot,
            operations: operations,
            operationCount: operationCount,
            copyCount: copyCount,
            updatedCount: updatedCount,
            createdDirectoryCount: createdDirectoryCount,
            deletedFileCount: deletedFileCount,
            deletedDirectoryCount: deletedDirectoryCount,
            totalCopyBytes: totalCopyBytes,
            totalDeleteBytes: totalDeleteBytes,
            scannedAt: Date()
        )
    }

    private struct InventoryItem: Sendable {
        let url: URL
        let fileSizeBytes: Int64
        let modifiedDate: Date?
        let evidence: FolderSyncFileEvidence
    }

    private struct Inventory: Sendable {
        var files: [String: InventoryItem] = [:]
        var directories: [String: InventoryItem] = [:]
    }

    private static func inventory(
        at root: URL,
        includedFileExtensions: Set<String>? = nil
    ) throws -> Inventory {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var inventory = Inventory()
        var discoveredDirectories: [String: InventoryItem] = [:]
        var enumerationError: Error?

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let relativePath = relativePath(for: url, root: root) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                let modifiedDate = values?.contentModificationDate
                discoveredDirectories[relativePath] = InventoryItem(
                    url: url,
                    fileSizeBytes: 0,
                    modifiedDate: modifiedDate,
                    evidence: FolderSyncFileEvidence(
                        isDirectory: true,
                        fileSizeBytes: 0,
                        modificationDate: modifiedDate,
                        contentSignature: stableSignature([
                            "directory",
                            relativePath,
                            evidenceDateValue(modifiedDate)
                        ])
                    )
                )
            } else if values?.isRegularFile == true,
                fileExtensionIsIncluded(url.pathExtension, in: includedFileExtensions)
            {
                let fileSizeBytes = values?.fileSize.map(Int64.init) ?? 0
                let modifiedDate = values?.contentModificationDate
                inventory.files[relativePath] = InventoryItem(
                    url: url,
                    fileSizeBytes: fileSizeBytes,
                    modifiedDate: modifiedDate,
                    evidence: FolderSyncFileEvidence(
                        isDirectory: false,
                        fileSizeBytes: fileSizeBytes,
                        modificationDate: modifiedDate,
                        contentSignature: stableSignature([
                            "file",
                            relativePath,
                            String(fileSizeBytes),
                            evidenceDateValue(modifiedDate)
                        ])
                    )
                )
            }
        }

        if let enumerationError {
            throw enumerationError
        }

        discoveredDirectories = directoriesWithRecursiveEvidence(
            discoveredDirectories,
            files: inventory.files
        )

        if includedFileExtensions == nil {
            inventory.directories = discoveredDirectories
        } else {
            inventory.directories = directoriesContainingIncludedFiles(
                filePaths: inventory.files.keys,
                discoveredDirectories: discoveredDirectories
            )
        }

        return inventory
    }

    private static func directoriesWithRecursiveEvidence(
        _ directories: [String: InventoryItem],
        files: [String: InventoryItem]
    ) -> [String: InventoryItem] {
        Dictionary(uniqueKeysWithValues: directories.map { path, directory in
            let descendantDirectories = directories
                .filter { isPath($0.key, below: path) }
                .sorted { localizedPathSort($0.key, $1.key) }
            let descendantFiles = files
                .filter { isPath($0.key, below: path) }
                .sorted { localizedPathSort($0.key, $1.key) }
            let recursiveSize = descendantFiles.reduce(Int64(0)) { $0 + $1.value.fileSizeBytes }
            var signatureParts = [
                "directory",
                path,
                evidenceDateValue(directory.modifiedDate)
            ]
            signatureParts.append(contentsOf: descendantDirectories.flatMap { child in
                ["directory", child.key, evidenceDateValue(child.value.modifiedDate)]
            })
            signatureParts.append(contentsOf: descendantFiles.flatMap { child in
                [
                    "file",
                    child.key,
                    String(child.value.fileSizeBytes),
                    evidenceDateValue(child.value.modifiedDate)
                ]
            })
            let descendantCount = descendantDirectories.count + descendantFiles.count
            let evidence = FolderSyncFileEvidence(
                isDirectory: true,
                fileSizeBytes: recursiveSize,
                modificationDate: directory.modifiedDate,
                descendantCount: descendantCount,
                contentSignature: stableSignature(signatureParts)
            )
            return (
                path,
                InventoryItem(
                    url: directory.url,
                    fileSizeBytes: recursiveSize,
                    modifiedDate: directory.modifiedDate,
                    evidence: evidence
                )
            )
        })
    }

    private static func evidenceDateValue(_ date: Date?) -> String {
        guard let date else { return "missing" }
        return String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func stableSignature(_ parts: [String]) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in parts.joined(separator: "\u{1f}").utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    private static func directoriesContainingIncludedFiles(
        filePaths: Dictionary<String, InventoryItem>.Keys,
        discoveredDirectories: [String: InventoryItem]
    ) -> [String: InventoryItem] {
        var directories: [String: InventoryItem] = [:]
        for filePath in filePaths {
            var components = filePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            components.removeLast()
            while !components.isEmpty {
                let relativePath = components.joined(separator: "/")
                if let directory = discoveredDirectories[relativePath] {
                    directories[relativePath] = directory
                }
                components.removeLast()
            }
        }
        return directories
    }

    private static func shouldCopy(source: InventoryItem, destination: InventoryItem) -> Bool {
        guard source.fileSizeBytes == destination.fileSizeBytes else { return true }
        guard let sourceDate = source.modifiedDate,
            let destinationDate = destination.modifiedDate
        else {
            return false
        }
        return sourceDate.timeIntervalSince(destinationDate) > 0.5
    }

    private static func relativePath(for url: URL, root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents

        guard itemComponents.count > rootComponents.count,
            Array(itemComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func operationSort(_ left: FolderSyncOperation, _ right: FolderSyncOperation) -> Bool {
        guard operationRank(left.kind) == operationRank(right.kind) else {
            return operationRank(left.kind) < operationRank(right.kind)
        }
        if left.kind == .deleteDirectory && right.kind == .deleteDirectory {
            return deepestPathSort(left.relativePath, right.relativePath)
        }
        return localizedPathSort(left.relativePath, right.relativePath)
    }

    private static func operationRank(_ kind: FolderSyncOperationKind) -> Int {
        switch kind {
        case .createDirectory:
            0
        case .copyNew, .copyUpdated:
            1
        case .deleteFile:
            2
        case .deleteDirectory:
            3
        }
    }

    private static func localizedPathSort(_ left: String, _ right: String) -> Bool {
        left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }

    private static func deepestPathSort(_ left: String, _ right: String) -> Bool {
        let leftDepth = left.split(separator: "/").count
        let rightDepth = right.split(separator: "/").count
        guard leftDepth == rightDepth else { return leftDepth > rightDepth }
        return localizedPathSort(left, right)
    }

    private static func isPath(_ path: String, below ancestor: String) -> Bool {
        path.hasPrefix("\(ancestor)/")
    }

    private static func normalizedExtensions(_ extensions: Set<String>) -> Set<String> {
        Set(extensions.compactMap { extensionValue in
            let normalized = extensionValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func fileExtensionIsIncluded(
        _ fileExtension: String,
        in includedFileExtensions: Set<String>?
    ) -> Bool {
        guard let includedFileExtensions else { return true }
        return includedFileExtensions.contains(fileExtension.lowercased())
    }
}
