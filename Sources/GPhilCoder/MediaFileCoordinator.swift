import Foundation
import GPhilCoderCore

struct MediaCopyResult: Sendable {
    var total: Int
    var copied = 0
    var skippedExisting = 0
    var failed = 0
    var failedNames: [String] = []
    var createdDirectories = 0
    var failedDirectories = 0
    var failedDirectoryNames: [String] = []
    var cancelled = false

    init(total: Int = 0, cancelled: Bool = false) {
        self.total = total
        self.cancelled = cancelled
    }
}

struct MediaCopyRunConfiguration {
    let sourceRoot: URL?
    let destinationRoot: URL?
    let filter: MediaFileFilter
    let selectedExtensions: Set<String>?
    let fileNameFilter: MediaFileNameFilter
    let previewLimit: Int
}

@MainActor
final class MediaFileCoordinator {
    private let setCopyPlan: @MainActor (MediaCopyPlan?) -> Void
    private let setProgress: @MainActor (MediaCopyProgress?) -> Void
    private let setScanning: @MainActor (Bool) -> Void
    private let setCopying: @MainActor (Bool) -> Void
    private let setStatusMessage: @MainActor (String) -> Void
    private let resetForCopyRun: @MainActor () -> Void
    private let validateFolders: @MainActor (_ sourceRoot: URL, _ destinationRoot: URL) -> Bool
    private let promptConflictResolution: @MainActor ([MediaCopyPlan]) -> MediaCopyConflictResolution?
    private let notifyCompletion: @MainActor (_ title: String, _ body: String) -> Void

    private var mediaCopyTask: Task<Void, Never>?

    init(
        setCopyPlan: @escaping @MainActor (MediaCopyPlan?) -> Void,
        setProgress: @escaping @MainActor (MediaCopyProgress?) -> Void,
        setScanning: @escaping @MainActor (Bool) -> Void,
        setCopying: @escaping @MainActor (Bool) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        resetForCopyRun: @escaping @MainActor () -> Void,
        validateFolders: @escaping @MainActor (_ sourceRoot: URL, _ destinationRoot: URL) -> Bool,
        promptConflictResolution: @escaping @MainActor ([MediaCopyPlan]) -> MediaCopyConflictResolution?,
        notifyCompletion: @escaping @MainActor (_ title: String, _ body: String) -> Void
    ) {
        self.setCopyPlan = setCopyPlan
        self.setProgress = setProgress
        self.setScanning = setScanning
        self.setCopying = setCopying
        self.setStatusMessage = setStatusMessage
        self.resetForCopyRun = resetForCopyRun
        self.validateFolders = validateFolders
        self.promptConflictResolution = promptConflictResolution
        self.notifyCompletion = notifyCompletion
    }

    func scanCopyFiles(configuration: MediaCopyRunConfiguration) {
        runCopyPreflight(copyAfterScan: false, configuration: configuration)
    }

    func copyFilteredFiles(configuration: MediaCopyRunConfiguration) {
        runCopyPreflight(copyAfterScan: true, configuration: configuration)
    }

    func cancel() {
        mediaCopyTask?.cancel()
        mediaCopyTask = nil
        setScanning(false)
        setCopying(false)
        setProgress(nil)
    }

    private func runCopyPreflight(
        copyAfterScan: Bool,
        configuration: MediaCopyRunConfiguration
    ) {
        guard let sourceRoot = configuration.sourceRoot,
            let destinationRoot = configuration.destinationRoot
        else {
            setStatusMessage("Choose source and destination folders before copying media files.")
            return
        }

        guard validateFolders(sourceRoot, destinationRoot) else {
            return
        }

        mediaCopyTask?.cancel()
        resetForCopyRun()
        setScanning(true)
        setCopying(false)

        let filter = configuration.filter
        let selectedExtensions = configuration.selectedExtensions
        let fileNameFilter = configuration.fileNameFilter
        let candidateLimit = copyAfterScan ? nil : configuration.previewLimit
        setStatusMessage(
            "Scanning \(filter.fileTypeName) files in \(sourceRoot.lastPathComponent)..."
        )

        mediaCopyTask = Task { [weak self] in
            await self?.runCopyTask(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                filter: filter,
                selectedExtensions: selectedExtensions,
                fileNameFilter: fileNameFilter,
                candidateLimit: candidateLimit,
                copyAfterScan: copyAfterScan
            )
        }
    }

    private func runCopyTask(
        sourceRoot: URL,
        destinationRoot: URL,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>?,
        fileNameFilter: MediaFileNameFilter,
        candidateLimit: Int?,
        copyAfterScan: Bool
    ) async {
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try MediaCopyPlanner.buildPlan(
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    filter: filter,
                    selectedExtensions: selectedExtensions,
                    fileNameFilter: fileNameFilter,
                    candidateLimit: candidateLimit
                )
            }
            let plan = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled else { return }

            setCopyPlan(plan)
            setScanning(false)

            guard copyAfterScan else {
                setStatusMessage(Self.mediaCopyScanStatusMessage(for: plan))
                mediaCopyTask = nil
                return
            }

            guard plan.hasCopyableContent else {
                let completionMessage =
                    "No \(filter.fileTypeName) files found in \(sourceRoot.lastPathComponent)."
                setStatusMessage(completionMessage)
                notifyCompletion("File copy finished", completionMessage)
                mediaCopyTask = nil
                return
            }

            guard let resolution = promptConflictResolution([plan]) else {
                setStatusMessage("Media copy cancelled.")
                mediaCopyTask = nil
                return
            }

            setCopying(true)
            let progressStartedAt = Date()
            setProgress(
                MediaCopyProgress(
                    completed: 0,
                    total: plan.candidates.count,
                    copied: 0,
                    skippedExisting: 0,
                    failed: 0,
                    copiedBytes: 0,
                    totalBytes: plan.totalSizeBytes,
                    startedAt: progressStartedAt,
                    updatedAt: progressStartedAt,
                    currentName: nil
                )
            )
            setStatusMessage(
                "Copying \(plan.candidates.count) \(filter.fileTypeName) file\(plan.candidates.count == 1 ? "" : "s")..."
            )

            let result = await copyMediaCopyPlan(plan, conflictResolution: resolution)

            guard !Task.isCancelled else { return }

            setCopying(false)
            mediaCopyTask = nil
            let completionMessage = Self.mediaCopyResultStatusMessage(
                result,
                filter: filter,
                destinationRoot: destinationRoot
            )
            setStatusMessage(completionMessage)
            notifyCompletion("File copy finished", completionMessage)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            setScanning(false)
            setCopying(false)
            mediaCopyTask = nil
            setStatusMessage("Media copy cancelled.")
        } catch {
            guard !Task.isCancelled else { return }
            setCopyPlan(nil)
            setProgress(nil)
            setScanning(false)
            setCopying(false)
            mediaCopyTask = nil
            setStatusMessage("Could not prepare media copy: \(error.localizedDescription)")
        }
    }

    private func copyMediaCopyPlan(
        _ plan: MediaCopyPlan,
        conflictResolution: MediaCopyConflictResolution
    ) async -> MediaCopyResult {
        var result = MediaCopyResult(total: plan.candidates.count)
        let progressStartedAt = Date()
        let totalBytes = plan.totalSizeBytes
        var copiedBytes: Int64 = 0

        if !plan.relativeDirectories.isEmpty {
            let failedDirectories = await Task.detached(priority: .userInitiated) {
                MediaCopyPlanner.createDirectories(for: plan)
            }.value
            result.failedDirectories = failedDirectories.count
            result.failedDirectoryNames = failedDirectories
            result.createdDirectories = plan.relativeDirectories.count - failedDirectories.count
        }

        for (index, candidate) in plan.candidates.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            setProgress(
                MediaCopyProgress(
                    completed: index,
                    total: plan.candidates.count,
                    copied: result.copied,
                    skippedExisting: result.skippedExisting,
                    failed: result.failed,
                    copiedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: candidate.name
                )
            )

            let itemResult = await Task.detached(priority: .userInitiated) {
                MediaCopyPlanner.copyCandidate(
                    candidate,
                    conflictResolution: conflictResolution
                )
            }.value

            switch itemResult {
            case .copied:
                result.copied += 1
                copiedBytes += candidate.fileSizeBytes
            case .skippedExisting:
                result.skippedExisting += 1
            case .failed(let name):
                result.failed += 1
                result.failedNames.append(name)
            }

            let progressUpdatedAt = Date()
            let progress = MediaCopyProgress(
                completed: index + 1,
                total: plan.candidates.count,
                copied: result.copied,
                skippedExisting: result.skippedExisting,
                failed: result.failed,
                copiedBytes: copiedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: progressUpdatedAt,
                currentName: candidate.name
            )
            setProgress(progress)
            let speedDetail = progress.bytesPerSecond
                .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
            setStatusMessage(
                "Copied \(result.copied), skipped \(result.skippedExisting), failed \(result.failed) of \(plan.candidates.count)\(speedDetail)."
            )
        }

        return result
    }

    private static func mediaCopyScanStatusMessage(for plan: MediaCopyPlan) -> String {
        guard plan.hasCopyableContent else {
            return "No \(plan.filter.fileTypeName) files found in \(plan.sourceRoot.lastPathComponent)."
        }

        var details = [
            "Found \(plan.candidateCount) \(plan.filter.fileTypeName) file\(plan.candidateCount == 1 ? "" : "s")",
            "totaling \(plan.totalSizeBytes.formattedFileSize)"
        ]
        if plan.directoryCount > 0 {
            details.append(
                "\(plan.directoryCount) folder\(plan.directoryCount == 1 ? "" : "s")"
            )
        }
        if plan.conflictCount > 0 {
            details.append(
                "\(plan.conflictCount) existing destination file\(plan.conflictCount == 1 ? "" : "s")"
            )
        }
        return details.joined(separator: ", ") + "."
    }

    private static func mediaCopyResultStatusMessage(
        _ result: MediaCopyResult,
        filter: MediaFileFilter,
        destinationRoot: URL
    ) -> String {
        if result.cancelled {
            return "Media copy cancelled after \(result.copied) copied file\(result.copied == 1 ? "" : "s")."
        }

        var details = [
            "Copied \(result.copied) \(filter.fileTypeName) file\(result.copied == 1 ? "" : "s") to \(destinationRoot.lastPathComponent)."
        ]
        if result.createdDirectories > 0 {
            details.append(
                "Created \(result.createdDirectories) folder\(result.createdDirectories == 1 ? "" : "s")."
            )
        }
        if result.skippedExisting > 0 {
            details.append("Skipped \(result.skippedExisting) existing file\(result.skippedExisting == 1 ? "" : "s").")
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        if result.failedDirectories > 0 {
            details.append(
                "Failed \(result.failedDirectories) folder\(result.failedDirectories == 1 ? "" : "s"): \(result.failedDirectoryNames.prefix(3).joined(separator: ", "))\(result.failedDirectoryNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }
}
