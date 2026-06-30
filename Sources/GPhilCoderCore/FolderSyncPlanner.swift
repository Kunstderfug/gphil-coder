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

public struct FolderSyncOperation: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: FolderSyncOperationKind
    public let sourceURL: URL?
    public let destinationURL: URL
    public let relativePath: String
    public let fileSizeBytes: Int64

    public init(
        kind: FolderSyncOperationKind,
        sourceURL: URL?,
        destinationURL: URL,
        relativePath: String,
        fileSizeBytes: Int64 = 0
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
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
        syncDeletes: Bool = true,
        operationLimit: Int? = nil
    ) throws -> FolderSyncPlan {
        let originInventory = try inventory(at: originRoot)
        let destinationInventory = try inventory(at: destinationRoot)
        var operations: [FolderSyncOperation] = []
        var operationCount = 0
        var copyCount = 0
        var updatedCount = 0
        var createdDirectoryCount = 0
        var deletedFileCount = 0
        var deletedDirectoryCount = 0
        var totalCopyBytes: Int64 = 0

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
            case .deleteDirectory:
                deletedDirectoryCount += 1
            }

            if operationLimit.map({ operations.count < $0 }) ?? true {
                operations.append(operation)
            }
        }

        let originDirectoryPaths = originInventory.directories.keys.sorted(by: localizedPathSort)
        for relativePath in originDirectoryPaths
        where destinationInventory.directories[relativePath] == nil {
            append(
                FolderSyncOperation(
                    kind: .createDirectory,
                    sourceURL: originInventory.directories[relativePath]?.url,
                    destinationURL: destinationRoot.appendingPathComponent(relativePath, isDirectory: true),
                    relativePath: relativePath
                )
            )
        }

        let originFilePaths = originInventory.files.keys.sorted(by: localizedPathSort)
        for relativePath in originFilePaths {
            guard let sourceFile = originInventory.files[relativePath] else { continue }
            let destinationURL = destinationRoot.appendingPathComponent(relativePath, isDirectory: false)

            guard let destinationFile = destinationInventory.files[relativePath] else {
                append(
                    FolderSyncOperation(
                        kind: .copyNew,
                        sourceURL: sourceFile.url,
                        destinationURL: destinationURL,
                        relativePath: relativePath,
                        fileSizeBytes: sourceFile.fileSizeBytes
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
                        fileSizeBytes: sourceFile.fileSizeBytes
                    )
                )
            }
        }

        if syncDeletes {
            let destinationDirectoryPaths = destinationInventory.directories.keys
                .filter { originInventory.directories[$0] == nil }
                .sorted { left, right in
                    let leftDepth = left.split(separator: "/").count
                    let rightDepth = right.split(separator: "/").count
                    guard leftDepth == rightDepth else { return leftDepth < rightDepth }
                    return localizedPathSort(left, right)
                }
            var deletedDirectoryPrefixes: [String] = []
            for relativePath in destinationDirectoryPaths {
                guard !deletedDirectoryPrefixes.contains(where: { isPath(relativePath, below: $0) })
                else { continue }
                deletedDirectoryPrefixes.append(relativePath)
            }

            let destinationFilePaths = destinationInventory.files.keys
                .filter { originInventory.files[$0] == nil }
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
                        fileSizeBytes: destinationFile.fileSizeBytes
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
                        relativePath: relativePath
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
            scannedAt: Date()
        )
    }

    public static func applyOperation(
        _ operation: FolderSyncOperation,
        overwriteExisting: Bool = true
    ) -> FolderSyncOperationResult {
        let fileManager = FileManager.default

        do {
            switch operation.kind {
            case .createDirectory:
                try fileManager.createDirectory(
                    at: operation.destinationURL,
                    withIntermediateDirectories: true
                )
            case .copyNew, .copyUpdated:
                guard let sourceURL = operation.sourceURL else {
                    return .failed(operation.relativePath)
                }
                try fileManager.createDirectory(
                    at: operation.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var isDirectory: ObjCBool = false
                let destinationExists = fileManager.fileExists(
                    atPath: operation.destinationURL.path,
                    isDirectory: &isDirectory
                )
                guard !destinationExists || !isDirectory.boolValue else {
                    return .failed(operation.relativePath)
                }
                if destinationExists, !overwriteExisting {
                    return .skippedExisting
                }
                if destinationExists {
                    try replaceFile(at: operation.destinationURL, with: sourceURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: operation.destinationURL)
                }
            case .deleteFile, .deleteDirectory:
                guard fileManager.fileExists(atPath: operation.destinationURL.path) else {
                    return .applied
                }
                try fileManager.removeItem(at: operation.destinationURL)
            }
            return .applied
        } catch {
            return .failed(operation.relativePath)
        }
    }

    private struct InventoryItem: Sendable {
        let url: URL
        let fileSizeBytes: Int64
        let modifiedDate: Date?
    }

    private struct Inventory: Sendable {
        var files: [String: InventoryItem] = [:]
        var directories: [String: InventoryItem] = [:]
    }

    private static func inventory(at root: URL) throws -> Inventory {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var inventory = Inventory()

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let relativePath = relativePath(for: url, root: root) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                inventory.directories[relativePath] = InventoryItem(
                    url: url,
                    fileSizeBytes: 0,
                    modifiedDate: values?.contentModificationDate
                )
            } else if values?.isRegularFile == true {
                inventory.files[relativePath] = InventoryItem(
                    url: url,
                    fileSizeBytes: values?.fileSize.map(Int64.init) ?? 0,
                    modifiedDate: values?.contentModificationDate
                )
            }
        }

        return inventory
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

    private static func replaceFile(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".gphilcoder-sync-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
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
}
