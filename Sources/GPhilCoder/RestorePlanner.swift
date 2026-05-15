import CryptoKit
import Foundation

enum RestoreCopySource: String, CaseIterable, Identifiable, Sendable {
    case deleted
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deleted:
            "Deleted folder"
        case .backup:
            "Backup tree"
        }
    }
}

enum RestoreMatchMode: String, CaseIterable, Identifiable, Sendable {
    case filenameAndSize
    case filenameOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filenameAndSize:
            "Filename + size"
        case .filenameOnly:
            "Filename only"
        }
    }

    var detail: String {
        switch self {
        case .filenameAndSize:
            "Safest: requires the same filename and exact byte size."
        case .filenameOnly:
            "Diagnostic: matches by filename even when byte sizes differ."
        }
    }

    var matchDescription: String {
        switch self {
        case .filenameAndSize:
            "filename and byte size"
        case .filenameOnly:
            "filename only"
        }
    }
}

enum RestoreHashMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            "Auto"
        case .always:
            "Always"
        case .never:
            "Never"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            "Hash only duplicate matching candidates."
        case .always:
            "Hash every candidate before accepting a match."
        case .never:
            "Trust the selected match mode without hashing."
        }
    }
}

enum RestorePlanStatus: String, CaseIterable, Sendable {
    case alreadyRestored
    case matched
    case matchedConflict
    case ambiguous
    case missing

    var title: String {
        switch self {
        case .alreadyRestored:
            "Restored"
        case .matched:
            "Backup Match"
        case .matchedConflict:
            "Target Exists"
        case .ambiguous:
            "Ambiguous"
        case .missing:
            "Missing"
        }
    }
}

enum RestorePlanProgressPhase: String, Sendable {
    case scanningDeleted
    case scanningRestore
    case checkingRestore
    case scanningBackup
    case matching

    var title: String {
        switch self {
        case .scanningDeleted:
            "Scanning deleted files"
        case .scanningRestore:
            "Scanning restore root"
        case .checkingRestore:
            "Checking restored files"
        case .scanningBackup:
            "Scanning backup tree"
        case .matching:
            "Matching backup files"
        }
    }
}

struct RestorePlanProgress: Equatable, Sendable {
    let phase: RestorePlanProgressPhase
    let completed: Int
    let total: Int?
    let detail: String
    let statusCounts: RestorePlanStatusCounts?
    let unresolvedItems: [RestoreUnresolvedFile]?

    init(
        phase: RestorePlanProgressPhase,
        completed: Int,
        total: Int?,
        detail: String,
        statusCounts: RestorePlanStatusCounts? = nil,
        unresolvedItems: [RestoreUnresolvedFile]? = nil
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
        self.statusCounts = statusCounts
        self.unresolvedItems = unresolvedItems
    }

    var title: String {
        phase.title
    }

    var countText: String {
        if let total {
            "\(min(completed, total)) / \(total)"
        } else {
            "\(completed) found"
        }
    }
}

struct RestorePlanStatusCounts: Equatable, Sendable {
    var deletedTotal = 0
    var alreadyRestored = 0
    var matched = 0
    var conflict = 0
    var ambiguous = 0
    var missing = 0

    var unresolvedFromRestore: Int {
        max(0, deletedTotal - alreadyRestored)
    }

    var summary: String {
        "\(alreadyRestored) restored, \(unresolvedFromRestore) unresolved, \(matched) backup matches, \(conflict) target exists, \(ambiguous) ambiguous, \(missing) missing."
    }
}

struct RestoreUnresolvedFile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let matchName: String?
    let deletedPath: String
    let size: Int64
}

struct RestorePlanRecord: Identifiable, Sendable {
    let id = UUID()
    let status: RestorePlanStatus
    let deletedURL: URL
    let backupURL: URL?
    let restoreURL: URL?
    let relativePath: String?
    let size: Int64
    let sha256: String?
    let note: String
    let candidates: [URL]

    var displayName: String {
        deletedURL.lastPathComponent
    }

    var sourceURLForDeletedCopy: URL {
        deletedURL
    }
}

struct RestorePlanScanSummary: Equatable, Sendable {
    let deletedFileCount: Int
    let restoreCandidateCount: Int
    let restoreScannedCount: Int
    let unresolvedFileCount: Int
    let backupCandidateCount: Int
    let backupScannedCount: Int

    var detail: String {
        "\(deletedFileCount) deleted, \(restoreCandidateCount) restore-root candidates after scanning \(restoreScannedCount), \(unresolvedFileCount) sent to backup, \(backupCandidateCount) backup candidates after scanning \(backupScannedCount)."
    }
}

struct RestorePlanBuildResult: Sendable {
    let records: [RestorePlanRecord]
    let scanSummary: RestorePlanScanSummary
}

struct RestorePlanOptions: Sendable {
    let deletedFolder: URL
    let backupRoot: URL
    let restoreRoot: URL
    let matchMode: RestoreMatchMode
    let hashMode: RestoreHashMode
    let includeHidden: Bool
}

struct RestoreApplyResult: Sendable {
    var copied = 0
    var skipped = 0
    var failed = 0
    var restoredURLs: [URL] = []
    var failedNames: [String] = []
}

private struct RestoreFileInfo: Sendable {
    let url: URL
    let nameKey: String
    let matchName: String
    let size: Int64
}

private struct RestoreScanResult: Sendable {
    let files: [RestoreFileInfo]
    let scannedCount: Int
}

private struct RestoreMatchKey: Hashable, Sendable {
    let nameKey: String
    let size: Int64?
}

typealias RestorePlanProgressHandler = @Sendable (RestorePlanProgress) -> Void

enum RestorePlanner {
    private static let scanProgressInterval = 100
    private static let matchingProgressInterval = 10
    private static let unresolvedListProgressInterval = 100

    static func buildPlan(
        options: RestorePlanOptions,
        progress: RestorePlanProgressHandler? = nil
    ) throws -> RestorePlanBuildResult {
        let backupRoot = options.backupRoot.standardizedFileURL.resolvingSymlinksInPath()
        let deletedFolder = options.deletedFolder.standardizedFileURL.resolvingSymlinksInPath()
        let restoreRoot = options.restoreRoot.standardizedFileURL
        let matchMode = options.matchMode

        let deletedScan = try scanFiles(
            root: deletedFolder,
            includeHidden: options.includeHidden,
            phase: .scanningDeleted,
            progress: progress,
            matchingKeys: nil,
            matchMode: matchMode
        )
        let deletedFiles = deletedScan.files
        let deletedKeys = Set(deletedFiles.map { matchKey(for: $0, mode: matchMode) })
        let restoreScan = try scanFiles(
            root: restoreRoot,
            includeHidden: options.includeHidden,
            phase: .scanningRestore,
            progress: progress,
            matchingKeys: deletedKeys,
            matchMode: matchMode
        )
        let restoreFiles = restoreScan.files
        var hashCache: [String: String] = [:]
        var records: [RestorePlanRecord] = []
        var unresolvedDeletedFiles: [RestoreFileInfo] = []
        var liveBackupUnresolvedFiles: [RestoreFileInfo] = []
        var restoreIndex = Dictionary(grouping: restoreFiles) { matchKey(for: $0, mode: matchMode) }
        var statusCounts = RestorePlanStatusCounts(deletedTotal: deletedFiles.count)

        func statusSummary() -> String {
            statusCounts.summary
        }

        func emitRestoreCheckProgress(completed: Int, force: Bool = false) {
            guard force || completed == deletedFiles.count || completed % matchingProgressInterval == 0
            else {
                return
            }
            progress?(
                RestorePlanProgress(
                    phase: .checkingRestore,
                    completed: completed,
                    total: deletedFiles.count,
                    detail: "\(restoreFiles.count) restore-root candidate\(restoreFiles.count == 1 ? "" : "s"); \(statusCounts.alreadyRestored) restored, \(statusCounts.unresolvedFromRestore) unresolved.",
                    statusCounts: statusCounts,
                    unresolvedItems: force || completed == deletedFiles.count
                        ? unresolvedItems(from: unresolvedDeletedFiles)
                        : nil
                )
            )
        }

        func emitBackupMatchingProgress(completed: Int, total: Int, force: Bool = false) {
            guard force || completed == total || completed % matchingProgressInterval == 0
            else {
                return
            }
            let includeUnresolvedItems =
                force || completed == total || completed % unresolvedListProgressInterval == 0
            progress?(
                RestorePlanProgress(
                    phase: .matching,
                    completed: completed,
                    total: total,
                    detail:
                        "\(statusSummary()) \(liveBackupUnresolvedFiles.count) still waiting for backup classification.",
                    statusCounts: statusCounts,
                    unresolvedItems: includeUnresolvedItems
                        ? unresolvedItems(from: liveBackupUnresolvedFiles)
                        : nil
                )
            )
        }

        func appendRecord(_ record: RestorePlanRecord) {
            records.append(record)
            switch record.status {
            case .alreadyRestored:
                statusCounts.alreadyRestored += 1
            case .matched:
                statusCounts.matched += 1
            case .matchedConflict:
                statusCounts.conflict += 1
            case .ambiguous:
                statusCounts.ambiguous += 1
            case .missing:
                statusCounts.missing += 1
            }
        }

        progress?(
            RestorePlanProgress(
                phase: .checkingRestore,
                completed: 0,
                total: deletedFiles.count,
                detail: "Checking \(deletedFiles.count) deleted file\(deletedFiles.count == 1 ? "" : "s") against the restore root."
            )
        )

        for (index, deleted) in deletedFiles.enumerated() {
            try Task.checkCancellation()
            let key = matchKey(for: deleted, mode: matchMode)
            var candidates = restoreIndex[key] ?? []
            if !candidates.isEmpty {
                let match = try matchingCandidates(
                    for: deleted,
                    candidates: candidates,
                    hashMode: options.hashMode,
                    hashCache: &hashCache
                )
                if let restored = match.candidates.first {
                    remove(restored, from: &candidates)
                    restoreIndex[key] = candidates.isEmpty ? nil : candidates
                    let relativePath = relativePathString(for: restored.url, backupRoot: restoreRoot)
                    let note =
                        match.candidates.count > 1
                        ? "Already exists in the restore root at one of \(match.candidates.count) paths matching by \(matchMode.matchDescription); skipping backup search for this copy."
                        : "Already exists in the restore root by \(matchMode.matchDescription); skipping backup search."
                    appendRecord(
                        RestorePlanRecord(
                            status: .alreadyRestored,
                            deletedURL: deleted.url,
                            backupURL: nil,
                            restoreURL: restored.url,
                            relativePath: relativePath,
                            size: deleted.size,
                            sha256: match.digest,
                            note: note,
                            candidates: match.candidates.map(\.url)
                        )
                    )
                } else {
                    unresolvedDeletedFiles.append(deleted)
                }
            } else {
                unresolvedDeletedFiles.append(deleted)
            }
            emitRestoreCheckProgress(completed: index + 1)
        }
        emitRestoreCheckProgress(completed: deletedFiles.count, force: true)

        guard !unresolvedDeletedFiles.isEmpty else {
            return RestorePlanBuildResult(
                records: sorted(records),
                scanSummary: RestorePlanScanSummary(
                    deletedFileCount: deletedFiles.count,
                    restoreCandidateCount: restoreFiles.count,
                    restoreScannedCount: restoreScan.scannedCount,
                    unresolvedFileCount: 0,
                    backupCandidateCount: 0,
                    backupScannedCount: 0
                )
            )
        }

        let unresolvedKeys = Set(unresolvedDeletedFiles.map { matchKey(for: $0, mode: matchMode) })
        let backupScan = try scanFiles(
            root: backupRoot,
            includeHidden: options.includeHidden,
            phase: .scanningBackup,
            progress: progress,
            matchingKeys: unresolvedKeys,
            matchMode: matchMode
        )
        let backupFiles = backupScan.files
        let backupIndex = Dictionary(grouping: backupFiles) { matchKey(for: $0, mode: matchMode) }
        liveBackupUnresolvedFiles = unresolvedDeletedFiles

        progress?(
            RestorePlanProgress(
                phase: .matching,
                completed: 0,
                total: unresolvedDeletedFiles.count,
                detail:
                    "Matching \(unresolvedDeletedFiles.count) unresolved file\(unresolvedDeletedFiles.count == 1 ? "" : "s") against \(backupFiles.count) backup candidate\(backupFiles.count == 1 ? "" : "s").",
                statusCounts: statusCounts,
                unresolvedItems: unresolvedItems(from: liveBackupUnresolvedFiles)
            )
        )

        for (index, deleted) in unresolvedDeletedFiles.enumerated() {
            try Task.checkCancellation()
            let key = matchKey(for: deleted, mode: matchMode)
            var candidates = backupIndex[key] ?? []
            guard !candidates.isEmpty else {
                appendRecord(
                    RestorePlanRecord(
                        status: .missing,
                        deletedURL: deleted.url,
                        backupURL: nil,
                        restoreURL: nil,
                        relativePath: nil,
                        size: deleted.size,
                        sha256: nil,
                        note: "No backup file with the same \(matchMode.matchDescription).",
                        candidates: []
                    )
                )
                remove(deleted, from: &liveBackupUnresolvedFiles)
                emitBackupMatchingProgress(completed: index + 1, total: unresolvedDeletedFiles.count)
                continue
            }

            let backupMatch: (digest: String?, candidates: [RestoreFileInfo])
            if options.hashMode == .always || (options.hashMode == .auto && candidates.count > 1) {
                progress?(
                    RestorePlanProgress(
                        phase: .matching,
                        completed: index,
                        total: unresolvedDeletedFiles.count,
                        detail: "Verifying \(deleted.url.lastPathComponent) with SHA-256."
                    )
                )
            }
            backupMatch = try matchingCandidates(
                for: deleted,
                candidates: candidates,
                hashMode: options.hashMode,
                hashCache: &hashCache
            )
            candidates = backupMatch.candidates

            if candidates.count == 1 {
                let match = candidates[0]
                let relativePath = relativePathString(for: match.url, backupRoot: backupRoot)
                let restoreURL = restoreRoot.appendingPathComponent(relativePath, isDirectory: false)
                let conflict = FileManager.default.fileExists(atPath: restoreURL.path)
                let matchNote =
                    if backupMatch.digest == nil {
                        "Matched by \(matchMode.matchDescription)."
                    } else if matchMode == .filenameOnly {
                        "Matched by filename and SHA-256."
                    } else {
                        "Matched by filename, byte size, and SHA-256."
                    }

                appendRecord(
                    RestorePlanRecord(
                        status: conflict ? .matchedConflict : .matched,
                        deletedURL: deleted.url,
                        backupURL: match.url,
                        restoreURL: restoreURL,
                        relativePath: relativePath,
                        size: deleted.size,
                        sha256: backupMatch.digest,
                        note: conflict ? "\(matchNote) Restore path already exists." : matchNote,
                        candidates: candidates.map(\.url)
                    )
                )
            } else if candidates.isEmpty {
                appendRecord(
                    RestorePlanRecord(
                        status: .missing,
                        deletedURL: deleted.url,
                        backupURL: nil,
                        restoreURL: nil,
                        relativePath: nil,
                        size: deleted.size,
                        sha256: backupMatch.digest,
                        note: "Same \(matchMode.matchDescription) existed, but SHA-256 did not match.",
                        candidates: []
                    )
                )
            } else {
                appendRecord(
                    RestorePlanRecord(
                        status: .ambiguous,
                        deletedURL: deleted.url,
                        backupURL: nil,
                        restoreURL: nil,
                        relativePath: nil,
                        size: deleted.size,
                        sha256: backupMatch.digest,
                        note: "Multiple backup paths match; original path cannot be inferred safely.",
                        candidates: candidates.map(\.url)
                    )
                )
            }
            remove(deleted, from: &liveBackupUnresolvedFiles)
            emitBackupMatchingProgress(completed: index + 1, total: unresolvedDeletedFiles.count)
        }
        emitBackupMatchingProgress(
            completed: unresolvedDeletedFiles.count,
            total: unresolvedDeletedFiles.count,
            force: true
        )

        return RestorePlanBuildResult(
            records: sorted(records),
            scanSummary: RestorePlanScanSummary(
                deletedFileCount: deletedFiles.count,
                restoreCandidateCount: restoreFiles.count,
                restoreScannedCount: restoreScan.scannedCount,
                unresolvedFileCount: unresolvedDeletedFiles.count,
                backupCandidateCount: backupFiles.count,
                backupScannedCount: backupScan.scannedCount
            )
        )
    }

    private static func sorted(_ records: [RestorePlanRecord]) -> [RestorePlanRecord] {
        records.sorted {
            $0.deletedURL.lastPathComponent.localizedCaseInsensitiveCompare(
                $1.deletedURL.lastPathComponent
            ) == .orderedAscending
        }
    }

    static func apply(
        records: [RestorePlanRecord],
        copySource: RestoreCopySource,
        overwrite: Bool
    ) -> RestoreApplyResult {
        var result = RestoreApplyResult()

        for record in records where record.status == .matched || record.status == .matchedConflict {
            guard !Task.isCancelled else { break }
            guard let restoreURL = record.restoreURL else {
                result.skipped += 1
                continue
            }
            guard let sourceURL = sourceURL(for: record, copySource: copySource) else {
                result.skipped += 1
                continue
            }

            if FileManager.default.fileExists(atPath: restoreURL.path), !overwrite {
                result.skipped += 1
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: restoreURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: restoreURL.path), overwrite {
                    try FileManager.default.removeItem(at: restoreURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: restoreURL)
                result.copied += 1
                result.restoredURLs.append(restoreURL)
            } catch {
                result.failed += 1
                result.failedNames.append(record.displayName)
            }
        }

        return result
    }

    private static func sourceURL(
        for record: RestorePlanRecord,
        copySource: RestoreCopySource
    ) -> URL? {
        switch copySource {
        case .deleted:
            record.deletedURL
        case .backup:
            record.backupURL
        }
    }

    private static func scanFiles(
        root: URL,
        includeHidden: Bool,
        phase: RestorePlanProgressPhase,
        progress: RestorePlanProgressHandler?,
        matchingKeys: Set<RestoreMatchKey>?,
        matchMode: RestoreMatchMode
    ) throws -> RestoreScanResult {
        progress?(
            RestorePlanProgress(
                phase: phase,
                completed: 0,
                total: nil,
                detail: "Starting at \(root.path(percentEncoded: false))."
            )
        )

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isHiddenKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        else {
            return RestoreScanResult(files: [], scannedCount: 0)
        }

        var result: [RestoreFileInfo] = []
        var visited = 0
        var scannedFiles = 0
        let discoveredLabel = matchingKeys == nil ? "file" : "candidate file"
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited % scanProgressInterval == 0 {
                progress?(
                    RestorePlanProgress(
                        phase: phase,
                        completed: result.count,
                        total: nil,
                        detail:
                            "\(result.count) \(discoveredLabel)\(result.count == 1 ? "" : "s") found after visiting \(visited) entries."
                    )
                )
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if !includeHidden, values?.isHidden == true { continue }
            scannedFiles += 1
            let size = Int64(values?.fileSize ?? 0)
            let fileName = url.lastPathComponent
            let matchName =
                phase == .scanningDeleted ? trashTimestampStrippedFileName(fileName) : fileName
            let fileInfo = RestoreFileInfo(
                url: url,
                nameKey: normalizedFileNameKey(matchName),
                matchName: matchName,
                size: size
            )
            if let matchingKeys, !matchingKeys.contains(matchKey(for: fileInfo, mode: matchMode)) {
                continue
            }
            result.append(fileInfo)
        }
        progress?(
            RestorePlanProgress(
                phase: phase,
                completed: result.count,
                total: nil,
                detail:
                    "\(result.count) \(discoveredLabel)\(result.count == 1 ? "" : "s") discovered after scanning \(scannedFiles) file\(scannedFiles == 1 ? "" : "s")."
            )
        )
        return RestoreScanResult(files: result, scannedCount: scannedFiles)
    }

    private static func matchingCandidates(
        for deleted: RestoreFileInfo,
        candidates: [RestoreFileInfo],
        hashMode: RestoreHashMode,
        hashCache: inout [String: String]
    ) throws -> (digest: String?, candidates: [RestoreFileInfo]) {
        guard hashMode == .always || (hashMode == .auto && candidates.count > 1) else {
            return (nil, candidates)
        }

        let digest = try sha256(for: deleted.url, cache: &hashCache)
        let matches = try candidates.filter { candidate in
            try Task.checkCancellation()
            return try sha256(for: candidate.url, cache: &hashCache) == digest
        }
        return (digest, matches)
    }

    private static func matchKey(
        for file: RestoreFileInfo,
        mode: RestoreMatchMode
    ) -> RestoreMatchKey {
        switch mode {
        case .filenameAndSize:
            RestoreMatchKey(nameKey: file.nameKey, size: file.size)
        case .filenameOnly:
            RestoreMatchKey(nameKey: file.nameKey, size: nil)
        }
    }

    private static func unresolvedItems(from files: [RestoreFileInfo]) -> [RestoreUnresolvedFile] {
        files.sorted {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        .map { file in
            RestoreUnresolvedFile(
                id: file.url.standardizedFileURL.path,
                name: file.url.lastPathComponent,
                matchName: file.matchName == file.url.lastPathComponent ? nil : file.matchName,
                deletedPath: file.url.path(percentEncoded: false),
                size: file.size
            )
        }
    }

    private static func normalizedFileNameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .precomposedStringWithCanonicalMapping
    }

    private static func trashTimestampStrippedFileName(_ name: String) -> String {
        let fileExtension = (name as NSString).pathExtension
        guard !fileExtension.isEmpty else { return name }

        let suffixLength = fileExtension.count + 1
        guard name.count > suffixLength else { return name }

        let nameWithoutFinalExtension = String(name.dropLast(suffixLength))
        guard let separatorRange = nameWithoutFinalExtension.range(of: " ", options: .backwards)
        else {
            return name
        }

        let timestamp = String(nameWithoutFinalExtension[separatorRange.upperBound...])
        guard isTrashTimestampSuffix(timestamp) else { return name }

        let originalName = String(nameWithoutFinalExtension[..<separatorRange.lowerBound])
        guard !originalName.isEmpty,
            (originalName as NSString).pathExtension.lowercased() == fileExtension.lowercased()
        else {
            return name
        }

        return originalName
    }

    private static func isTrashTimestampSuffix(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        return parts[0].count <= 2 && parts[1].count == 2 && parts[2].count == 2
            && parts[3].count == 3
    }

    private static func remove(_ file: RestoreFileInfo, from candidates: inout [RestoreFileInfo]) {
        guard let index = candidates.firstIndex(where: { $0.url == file.url }) else { return }
        candidates.remove(at: index)
    }

    private static func relativePathString(for url: URL, backupRoot: URL) -> String {
        let rootComponents = backupRoot.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
            Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return url.lastPathComponent
        }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func sha256(for url: URL, cache: inout [String: String]) throws -> String {
        let key = url.standardizedFileURL.path
        if let cached = cache[key] {
            return cached
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        cache[key] = digest
        return digest
    }
}
