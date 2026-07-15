import Foundation
import GPhilCoderCore

struct RestoreUnresolvedCopyResult: Sendable {
    var copied = 0
    var failed = 0
    var copiedURLs: [URL] = []
    var failedNames: [String] = []
}

@MainActor
final class RestoreCoordinator {
    private let setRecords: @MainActor ([RestorePlanRecord]) -> Void
    private let setLiveCounts: @MainActor (RestorePlanStatusCounts?) -> Void
    private let setLiveUnresolvedItems: @MainActor ([RestoreUnresolvedFile]) -> Void
    private let setScanSummary: @MainActor (RestorePlanScanSummary?) -> Void
    private let setProgress: @MainActor (RestorePlanProgress?) -> Void
    private let setPlanning: @MainActor (Bool) -> Void
    private let setRestoring: @MainActor (Bool) -> Void
    private let setStoppedWithPartialResults: @MainActor (Bool) -> Void
    private let setStatusMessage: @MainActor (String) -> Void
    private let appendRestoredFileURLs: @MainActor ([URL]) -> Void

    private var buildTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var buildID = UUID()
    private var latestLiveCounts: RestorePlanStatusCounts?
    private var latestLiveUnresolvedItems: [RestoreUnresolvedFile] = []

    init(
        setRecords: @escaping @MainActor ([RestorePlanRecord]) -> Void,
        setLiveCounts: @escaping @MainActor (RestorePlanStatusCounts?) -> Void,
        setLiveUnresolvedItems: @escaping @MainActor ([RestoreUnresolvedFile]) -> Void,
        setScanSummary: @escaping @MainActor (RestorePlanScanSummary?) -> Void,
        setProgress: @escaping @MainActor (RestorePlanProgress?) -> Void,
        setPlanning: @escaping @MainActor (Bool) -> Void,
        setRestoring: @escaping @MainActor (Bool) -> Void,
        setStoppedWithPartialResults: @escaping @MainActor (Bool) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        appendRestoredFileURLs: @escaping @MainActor ([URL]) -> Void
    ) {
        self.setRecords = setRecords
        self.setLiveCounts = setLiveCounts
        self.setLiveUnresolvedItems = setLiveUnresolvedItems
        self.setScanSummary = setScanSummary
        self.setProgress = setProgress
        self.setPlanning = setPlanning
        self.setRestoring = setRestoring
        self.setStoppedWithPartialResults = setStoppedWithPartialResults
        self.setStatusMessage = setStatusMessage
        self.appendRestoredFileURLs = appendRestoredFileURLs
    }

    func buildPlan(options: RestorePlanOptions) {
        buildTask?.cancel()
        let buildID = UUID()
        self.buildID = buildID
        latestLiveCounts = RestorePlanStatusCounts()
        latestLiveUnresolvedItems.removeAll()
        setRecords([])
        setScanSummary(nil)
        setLiveCounts(latestLiveCounts)
        setLiveUnresolvedItems([])
        setStoppedWithPartialResults(false)
        setProgress(
            RestorePlanProgress(
                phase: .scanningDeleted,
                completed: 0,
                total: nil,
                detail: "Preparing deleted-folder scan."
            )
        )
        setPlanning(true)
        setStatusMessage("Scanning deleted files and checking the restore root...")

        let progressHandler: RestorePlanProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self, buildID] in
                self?.apply(progress, for: buildID)
            }
        }

        buildTask = Task { [weak self, buildID] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try RestorePlanner.buildPlan(options: options, progress: progressHandler)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.completeBuild(result, for: buildID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failBuild(error, for: buildID)
            }
        }
    }

    func apply(records: [RestorePlanRecord], copySource: RestoreCopySource, overwrite: Bool) {
        applyTask?.cancel()
        setProgress(nil)
        setRestoring(true)
        setStatusMessage("Restoring matched files...")

        applyTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                RestorePlanner.apply(records: records, copySource: copySource, overwrite: overwrite)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.completeApply(result)
        }
    }

    func copyUnresolvedItems(_ items: [RestoreUnresolvedFile], to destinationFolder: URL) {
        applyTask?.cancel()
        setRestoring(true)
        setStatusMessage("Copying unresolved files to the restore root...")

        applyTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.copyUnresolvedItemsSynchronously(items, to: destinationFolder)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.completeUnresolvedCopy(result)
        }
    }

    func exportUnresolvedItems(_ request: RestoreUnresolvedExportRequest, to url: URL) {
        do {
            let exportURL = try RestoreUnresolvedExporter.export(request, to: url)
            setStatusMessage(
                "Exported \(request.items.count) unresolved file\(request.items.count == 1 ? "" : "s") to \(exportURL.lastPathComponent)."
            )
        } catch {
            setStatusMessage("Could not export unresolved files: \(error.localizedDescription)")
        }
    }

    func cancelBuild() {
        buildTask?.cancel()
        buildID = UUID()
        buildTask = nil
        setPlanning(false)
        setStoppedWithPartialResults(true)

        let unresolvedCount = latestLiveUnresolvedItems.count
        if unresolvedCount > 0 {
            setStatusMessage(
                "Stopped restore search. Kept partial snapshot with \(unresolvedCount) unresolved file\(unresolvedCount == 1 ? "" : "s")."
            )
        } else if let counts = latestLiveCounts, counts.deletedTotal > 0 {
            setStatusMessage("Stopped restore search. Kept partial counters: \(counts.summary)")
        } else {
            setStatusMessage("Stopped restore search before an unresolved snapshot was available.")
        }
    }

    private func apply(_ progress: RestorePlanProgress, for buildID: UUID) {
        guard self.buildID == buildID, buildTask != nil else { return }
        setProgress(progress)
        if let statusCounts = progress.statusCounts {
            latestLiveCounts = statusCounts
            setLiveCounts(statusCounts)
        }
        if let unresolvedItems = progress.unresolvedItems {
            latestLiveUnresolvedItems = unresolvedItems
            setLiveUnresolvedItems(unresolvedItems)
        }
        setStatusMessage("\(progress.title): \(progress.detail)")
    }

    private func completeBuild(_ result: RestorePlanBuildResult, for buildID: UUID) {
        guard self.buildID == buildID else { return }
        let records = result.records
        setRecords(records)
        latestLiveCounts = nil
        latestLiveUnresolvedItems.removeAll()
        setLiveCounts(nil)
        setLiveUnresolvedItems([])
        setScanSummary(result.scanSummary)
        setProgress(nil)
        setPlanning(false)
        setStoppedWithPartialResults(false)
        buildTask = nil
        setStatusMessage(Self.buildStatusMessage(records: records))
    }

    private func failBuild(_ error: Error, for buildID: UUID) {
        guard self.buildID == buildID else { return }
        setRecords([])
        latestLiveCounts = nil
        latestLiveUnresolvedItems.removeAll()
        setLiveCounts(nil)
        setLiveUnresolvedItems([])
        setScanSummary(nil)
        setProgress(nil)
        setPlanning(false)
        setStoppedWithPartialResults(false)
        buildTask = nil
        setStatusMessage("Could not build restore plan: \(error.localizedDescription)")
    }

    private func completeApply(_ result: RestoreApplyResult) {
        appendRestoredFileURLs(result.restoredURLs)
        setRestoring(false)
        applyTask = nil
        setStatusMessage(Self.applyStatusMessage(result))
    }

    private func completeUnresolvedCopy(_ result: RestoreUnresolvedCopyResult) {
        appendRestoredFileURLs(result.copiedURLs)
        setRestoring(false)
        applyTask = nil
        setStatusMessage(Self.unresolvedCopyStatusMessage(result))
    }

    private static func buildStatusMessage(records: [RestorePlanRecord]) -> String {
        "Restore plan built: \(records.filter { $0.status == .alreadyRestored }.count) restored, \(records.filter { $0.status == .matched }.count) backup matches, \(records.filter { $0.status == .matchedConflict }.count) target exists, \(records.filter { $0.status == .ambiguous }.count) ambiguous, \(records.filter { $0.status == .missing }.count) missing."
    }

    private static func applyStatusMessage(_ result: RestoreApplyResult) -> String {
        var details = [
            "Restored \(result.copied) file\(result.copied == 1 ? "" : "s")."
        ]
        if result.skipped > 0 {
            details.append("Skipped \(result.skipped).")
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    private static func unresolvedCopyStatusMessage(_ result: RestoreUnresolvedCopyResult) -> String {
        var details = [
            "Copied \(result.copied) unresolved file\(result.copied == 1 ? "" : "s") to GPhil MediaFlow Unresolved Files."
        ]
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    nonisolated private static func copyUnresolvedItemsSynchronously(
        _ items: [RestoreUnresolvedFile],
        to destinationFolder: URL
    ) -> RestoreUnresolvedCopyResult {
        var result = RestoreUnresolvedCopyResult()
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
        } catch {
            result.failed = items.count
            result.failedNames = Array(items.prefix(3).map(\.name))
            return result
        }

        for item in items {
            guard !Task.isCancelled else { break }

            let sourceURL = URL(fileURLWithPath: item.deletedPath)
            let preferredName = item.matchName ?? item.name
            let destinationURL = availableDestinationURL(
                in: destinationFolder,
                preferredName: preferredName
            )

            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                result.copied += 1
                result.copiedURLs.append(destinationURL)
            } catch {
                result.failed += 1
                result.failedNames.append(item.name)
            }
        }

        return result
    }
}
