import Foundation

public struct FolderSyncPairPlan: Identifiable, Sendable {
    public let pairID: UUID
    public let pairTitle: String
    public let plan: FolderSyncPlan

    public var id: UUID { pairID }

    public init(pairID: UUID, pairTitle: String, plan: FolderSyncPlan) {
        self.pairID = pairID
        self.pairTitle = pairTitle
        self.plan = plan
    }
}

public struct FolderSyncPairPlanningFailure: Identifiable, Sendable {
    public let pairID: UUID
    public let pairTitle: String
    public let originRoot: URL
    public let destinationRoot: URL
    public let errorDescription: String

    public var id: UUID { pairID }

    public init(
        pairID: UUID,
        pairTitle: String,
        originRoot: URL,
        destinationRoot: URL,
        errorDescription: String
    ) {
        self.pairID = pairID
        self.pairTitle = pairTitle
        self.originRoot = originRoot
        self.destinationRoot = destinationRoot
        self.errorDescription = errorDescription
    }
}

public struct FolderSyncBatchOperation: Identifiable, Sendable {
    public let pairID: UUID
    public let pairTitle: String
    public let originRoot: URL
    public let destinationRoot: URL
    public let operation: FolderSyncOperation

    public var id: String {
        "\(pairID.uuidString):\(operation.id)"
    }

    public var key: FolderSyncBatchOperationKey {
        FolderSyncBatchOperationKey(pairID: pairID, operationID: operation.id)
    }

    public init(pairPlan: FolderSyncPairPlan, operation: FolderSyncOperation) {
        pairID = pairPlan.pairID
        pairTitle = pairPlan.pairTitle
        originRoot = pairPlan.plan.originRoot
        destinationRoot = pairPlan.plan.destinationRoot
        self.operation = operation
    }
}

public struct FolderSyncBatchOperationKey: Hashable, Sendable {
    public let pairID: UUID
    public let operationID: String

    public init(pairID: UUID, operationID: String) {
        self.pairID = pairID
        self.operationID = operationID
    }
}

public enum FolderSyncBatchOperationDisposition: String, Codable, Sendable {
    case apply
    case skipExisting
    case conflict
}

public struct FolderSyncPairPreview: Identifiable, Sendable {
    public let pairID: UUID
    public let pairTitle: String
    public let originRoot: URL
    public let destinationRoot: URL
    public let totalOperationCount: Int
    public let operations: [FolderSyncBatchOperation]

    public var id: UUID { pairID }
    public var visibleOperationCount: Int { operations.count }
    public var hiddenOperationCount: Int {
        max(0, totalOperationCount - visibleOperationCount)
    }

    public init(
        pairID: UUID,
        pairTitle: String,
        originRoot: URL,
        destinationRoot: URL,
        totalOperationCount: Int,
        operations: [FolderSyncBatchOperation]
    ) {
        self.pairID = pairID
        self.pairTitle = pairTitle
        self.originRoot = originRoot
        self.destinationRoot = destinationRoot
        self.totalOperationCount = totalOperationCount
        self.operations = operations
    }
}

public struct FolderSyncBatchPreview: Sendable {
    public let groups: [FolderSyncPairPreview]
    public let planningFailures: [FolderSyncPairPlanningFailure]

    public var totalOperationCount: Int {
        groups.reduce(0) { $0 + $1.totalOperationCount }
    }

    public var visibleOperationCount: Int {
        groups.reduce(0) { $0 + $1.visibleOperationCount }
    }

    public var hiddenOperationCount: Int {
        groups.reduce(0) { $0 + $1.hiddenOperationCount }
    }

    public init(
        groups: [FolderSyncPairPreview],
        planningFailures: [FolderSyncPairPlanningFailure]
    ) {
        self.groups = groups
        self.planningFailures = planningFailures
    }
}

public struct FolderSyncBatchPlan: Identifiable, Sendable {
    public let id: UUID
    public let pairPlans: [FolderSyncPairPlan]
    public let planningFailures: [FolderSyncPairPlanningFailure]
    public let scannedAt: Date

    public init(
        id: UUID = UUID(),
        pairPlans: [FolderSyncPairPlan],
        planningFailures: [FolderSyncPairPlanningFailure] = [],
        scannedAt: Date = Date()
    ) {
        self.id = id
        self.pairPlans = pairPlans
        self.planningFailures = planningFailures
        self.scannedAt = scannedAt
    }

    public var operations: [FolderSyncBatchOperation] {
        pairPlans.flatMap { pairPlan in
            pairPlan.plan.operations.map {
                FolderSyncBatchOperation(pairPlan: pairPlan, operation: $0)
            }
        }
    }

    public var operationCount: Int { operations.count }

    public var copyCount: Int {
        operations.count { operation in
            operation.operation.kind == .copyNew || operation.operation.kind == .copyUpdated
        }
    }

    public var updatedCount: Int {
        operations.count { $0.operation.kind == .copyUpdated }
    }

    public var createdDirectoryCount: Int {
        operations.count { $0.operation.kind == .createDirectory }
    }

    public var deletedFileCount: Int {
        operations.count { $0.operation.kind == .deleteFile }
    }

    public var deletedDirectoryCount: Int {
        operations.count { $0.operation.kind == .deleteDirectory }
    }

    public var deleteCount: Int {
        deletedFileCount + deletedDirectoryCount
    }

    public var totalCopyBytes: Int64 {
        operations.reduce(0) { partialResult, operation in
            switch operation.operation.kind {
            case .copyNew, .copyUpdated:
                partialResult + operation.operation.fileSizeBytes
            case .createDirectory, .deleteFile, .deleteDirectory:
                partialResult
            }
        }
    }

    public var totalDeleteBytes: Int64 {
        operations.reduce(0) { partialResult, operation in
            switch operation.operation.kind {
            case .deleteFile, .deleteDirectory:
                partialResult + operation.operation.fileSizeBytes
            case .createDirectory, .copyNew, .copyUpdated:
                partialResult
            }
        }
    }

    public var hasWork: Bool { !operations.isEmpty }
    public var isComplete: Bool { planningFailures.isEmpty }
    public var isApplyable: Bool { isComplete && hasWork }

    public var operationFingerprint: [FolderSyncBatchOperationFingerprint] {
        operations.map(FolderSyncBatchOperationFingerprint.init)
    }

    public func hasSameOperations(as other: FolderSyncBatchPlan) -> Bool {
        isComplete && other.isComplete && operationFingerprint == other.operationFingerprint
    }

    public func destructiveSummary(overwriteExisting: Bool) -> FolderSyncDestructiveSummary {
        let destructiveOperations = operations.filter { batchOperation in
            switch batchOperation.operation.kind {
            case .deleteFile, .deleteDirectory:
                true
            case .copyUpdated:
                overwriteExisting
            case .createDirectory, .copyNew:
                false
            }
        }
        let affectedPairIDs = Set(destructiveOperations.map(\.pairID))
        let pairTitles = pairPlans
            .filter { affectedPairIDs.contains($0.pairID) }
            .map(\.pairTitle)
        let deleted = destructiveOperations.filter {
            $0.operation.kind == .deleteFile || $0.operation.kind == .deleteDirectory
        }
        let overwritten = destructiveOperations.filter { $0.operation.kind == .copyUpdated }
        return FolderSyncDestructiveSummary(
            affectedPairCount: affectedPairIDs.count,
            pairTitles: pairTitles,
            deleteCount: deleted.count,
            deleteBytes: deleted.reduce(0) { $0 + $1.operation.fileSizeBytes },
            overwriteCount: overwritten.count,
            overwriteBytes: overwritten.reduce(0) {
                $0 + ($1.operation.destinationEvidence?.fileSizeBytes ?? 0)
            }
        )
    }

    public func preview(limit: Int) -> FolderSyncBatchPreview {
        let workBearingPairs = pairPlans.filter { !$0.plan.operations.isEmpty }
        let guaranteedRowsPerPair = limit > 0 ? 1 : 0
        var additionalRowBudget = max(
            0,
            limit - (guaranteedRowsPerPair * workBearingPairs.count)
        )
        let groups = workBearingPairs.map { pairPlan in
            let completeOperations = pairPlan.plan.operations.map {
                FolderSyncBatchOperation(pairPlan: pairPlan, operation: $0)
            }
            let additionalRows = min(
                max(0, completeOperations.count - guaranteedRowsPerPair),
                additionalRowBudget
            )
            additionalRowBudget -= additionalRows
            let visibleCount = guaranteedRowsPerPair + additionalRows
            return FolderSyncPairPreview(
                pairID: pairPlan.pairID,
                pairTitle: pairPlan.pairTitle,
                originRoot: pairPlan.plan.originRoot,
                destinationRoot: pairPlan.plan.destinationRoot,
                totalOperationCount: completeOperations.count,
                operations: Array(completeOperations.prefix(visibleCount))
            )
        }
        return FolderSyncBatchPreview(
            groups: groups,
            planningFailures: planningFailures
        )
    }

    public func disposition(
        for batchOperation: FolderSyncBatchOperation,
        overwriteExisting: Bool
    ) -> FolderSyncBatchOperationDisposition {
        operationDispositions(overwriteExisting: overwriteExisting)[batchOperation.key] ?? .apply
    }

    public func operationDispositions(
        overwriteExisting: Bool
    ) -> [FolderSyncBatchOperationKey: FolderSyncBatchOperationDisposition] {
        let allOperations = operations
        let conflictRoots = Dictionary(grouping: allOperations.compactMap {
            batchOperation -> (pairID: UUID, relativePath: String)? in
            switch batchOperation.operation.kind {
            case .createDirectory:
                guard batchOperation.operation.destinationEvidence?.isDirectory == false
                else { return nil }
            case .copyNew, .copyUpdated:
                guard batchOperation.operation.destinationEvidence?.isDirectory == true
                else { return nil }
            case .deleteFile, .deleteDirectory:
                return nil
            }
            return (batchOperation.pairID, batchOperation.operation.relativePath)
        }, by: { $0.pairID })
        .mapValues { roots in roots.map { $0.relativePath } }

        return Dictionary(uniqueKeysWithValues: allOperations.map { batchOperation in
            let isConflict = conflictRoots[batchOperation.pairID, default: []].contains {
                batchOperation.operation.relativePath == $0
                    || batchOperation.operation.relativePath.hasPrefix($0 + "/")
            }
            let disposition: FolderSyncBatchOperationDisposition
            if isConflict {
                disposition = .conflict
            } else if batchOperation.operation.kind == .copyUpdated, !overwriteExisting {
                disposition = .skipExisting
            } else {
                disposition = .apply
            }
            return (batchOperation.key, disposition)
        })
    }

    public func retainingOperations(
        with keys: Set<FolderSyncBatchOperationKey>
    ) -> FolderSyncBatchPlan {
        let filteredPairPlans = pairPlans.compactMap { pairPlan -> FolderSyncPairPlan? in
            let operations = pairPlan.plan.operations.filter { operation in
                keys.contains(
                    FolderSyncBatchOperationKey(
                        pairID: pairPlan.pairID,
                        operationID: operation.id
                    )
                )
            }
            guard !operations.isEmpty else { return nil }
            let plan = FolderSyncPlan(
                originRoot: pairPlan.plan.originRoot,
                destinationRoot: pairPlan.plan.destinationRoot,
                operations: operations,
                operationCount: operations.count,
                copyCount: operations.count {
                    $0.kind == .copyNew || $0.kind == .copyUpdated
                },
                updatedCount: operations.count { $0.kind == .copyUpdated },
                createdDirectoryCount: operations.count { $0.kind == .createDirectory },
                deletedFileCount: operations.count { $0.kind == .deleteFile },
                deletedDirectoryCount: operations.count { $0.kind == .deleteDirectory },
                totalCopyBytes: operations.reduce(0) { total, operation in
                    switch operation.kind {
                    case .copyNew, .copyUpdated:
                        total + operation.fileSizeBytes
                    case .createDirectory, .deleteFile, .deleteDirectory:
                        total
                    }
                },
                totalDeleteBytes: operations.reduce(0) { total, operation in
                    switch operation.kind {
                    case .deleteFile, .deleteDirectory:
                        total + operation.fileSizeBytes
                    case .createDirectory, .copyNew, .copyUpdated:
                        total
                    }
                },
                scannedAt: pairPlan.plan.scannedAt
            )
            return FolderSyncPairPlan(
                pairID: pairPlan.pairID,
                pairTitle: pairPlan.pairTitle,
                plan: plan
            )
        }
        return FolderSyncBatchPlan(
            pairPlans: filteredPairPlans,
            planningFailures: planningFailures,
            scannedAt: scannedAt
        )
    }
}

public struct FolderSyncDestructiveSummary: Equatable, Sendable {
    public let affectedPairCount: Int
    public let pairTitles: [String]
    public let deleteCount: Int
    public let deleteBytes: Int64
    public let overwriteCount: Int
    public let overwriteBytes: Int64

    public init(
        affectedPairCount: Int,
        pairTitles: [String],
        deleteCount: Int,
        deleteBytes: Int64,
        overwriteCount: Int,
        overwriteBytes: Int64
    ) {
        self.affectedPairCount = affectedPairCount
        self.pairTitles = pairTitles
        self.deleteCount = deleteCount
        self.deleteBytes = deleteBytes
        self.overwriteCount = overwriteCount
        self.overwriteBytes = overwriteBytes
    }

    public var operationCount: Int { deleteCount + overwriteCount }
    public var hasDestructiveOperations: Bool { operationCount > 0 }
}

public struct FolderSyncBatchOperationFingerprint: Hashable, Sendable {
    public let pairID: UUID
    public let kind: FolderSyncOperationKind
    public let sourcePath: String?
    public let destinationPath: String
    public let relativePath: String
    public let fileSizeBytes: Int64
    public let sourceEvidence: FolderSyncFileEvidence?
    public let destinationEvidence: FolderSyncFileEvidence?

    public init(_ batchOperation: FolderSyncBatchOperation) {
        pairID = batchOperation.pairID
        kind = batchOperation.operation.kind
        sourcePath = batchOperation.operation.sourceURL?.standardizedFileURL.path
        destinationPath = batchOperation.operation.destinationURL.standardizedFileURL.path
        relativePath = batchOperation.operation.relativePath
        fileSizeBytes = batchOperation.operation.fileSizeBytes
        sourceEvidence = batchOperation.operation.sourceEvidence
        destinationEvidence = batchOperation.operation.destinationEvidence
    }
}
