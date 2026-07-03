import Foundation
import GPhilCoderCore

@MainActor
final class EncodingCoordinator {
    private let getJobs: @MainActor () -> [EncodeJob]
    private let setJobs: @MainActor ([EncodeJob]) -> Void
    private let setEncodingState: @MainActor (Bool) -> Void
    private let setStatusMessage: @MainActor (String) -> Void
    private let releaseScopes: @MainActor () -> Void
    private let notifyCompletion: @MainActor (_ title: String, _ body: String) -> Void
    private let processRegistry = ProcessRegistry()
    private var encodeTask: Task<Void, Never>?

    init(
        getJobs: @escaping @MainActor () -> [EncodeJob],
        setJobs: @escaping @MainActor ([EncodeJob]) -> Void,
        setEncodingState: @escaping @MainActor (Bool) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        releaseScopes: @escaping @MainActor () -> Void,
        notifyCompletion: @escaping @MainActor (_ title: String, _ body: String) -> Void
    ) {
        self.getJobs = getJobs
        self.setJobs = setJobs
        self.setEncodingState = setEncodingState
        self.setStatusMessage = setStatusMessage
        self.releaseScopes = releaseScopes
        self.notifyCompletion = notifyCompletion
    }

    func start(jobs plannedJobs: [EncodeJob], settings: EncodingSettingsSnapshot) {
        processRegistry.reset()
        setJobs(plannedJobs)
        setEncodingState(true)

        encodeTask = Task { [weak self] in
            await self?.runJobs(settings: settings)
        }
    }

    func cancel() {
        encodeTask?.cancel()
        processRegistry.terminateAll()
    }

    private var jobs: [EncodeJob] {
        get { getJobs() }
        set { setJobs(newValue) }
    }

    private func runJobs(settings: EncodingSettingsSnapshot) async {
        let processRegistry = processRegistry
        await withTaskGroup(of: EncodingJobResult.self) { group in
            var nextIndex = 0
            let initialCount = min(settings.parallelJobs, jobs.count)

            while nextIndex < initialCount {
                let job = markJobRunning(at: nextIndex)
                let reporter = EncodingProgressReporter(jobID: job.id) { [weak self] jobID, progress in
                    self?.updateJobProgress(jobID: jobID, progress: progress)
                }
                group.addTask {
                    await Self.encode(
                        job: job,
                        settings: settings,
                        progressReporter: reporter,
                        processRegistry: processRegistry
                    )
                }
                nextIndex += 1
            }

            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    apply(.cancelled(result.jobID))
                    continue
                }

                apply(result)

                if nextIndex < jobs.count {
                    let job = markJobRunning(at: nextIndex)
                    let reporter = EncodingProgressReporter(jobID: job.id) { [weak self] jobID, progress in
                        self?.updateJobProgress(jobID: jobID, progress: progress)
                    }
                    group.addTask {
                        await Self.encode(
                            job: job,
                            settings: settings,
                            progressReporter: reporter,
                            processRegistry: processRegistry
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        if Task.isCancelled {
            var updatedJobs = jobs
            for index in updatedJobs.indices
            where updatedJobs[index].state == .queued || updatedJobs[index].state == .running {
                updatedJobs[index].state = .cancelled
                updatedJobs[index].message = "Cancelled."
                updatedJobs[index].finishedAt = Date()
            }
            jobs = updatedJobs
        }

        setEncodingState(false)
        encodeTask = nil
        releaseScopes()

        let finalJobs = jobs
        let completedCount = finalJobs.filter { $0.state == .succeeded }.count
        let failedCount = finalJobs.filter { $0.state == .failed }.count
        let skippedCount = finalJobs.filter { $0.state == .skipped }.count

        let completionTitle: String
        let completionMessage: String
        if Task.isCancelled {
            completionTitle = "Encoding stopped"
            completionMessage =
                "Encoding cancelled. \(completedCount) completed, \(failedCount) failed, \(skippedCount) skipped."
        } else if failedCount > 0 {
            completionTitle = "Encoding finished with failures"
            completionMessage =
                "Finished with \(failedCount) failure\(failedCount == 1 ? "" : "s")."
        } else if skippedCount > 0 {
            completionTitle = "Encoding finished"
            completionMessage =
                "Finished. \(skippedCount) file\(skippedCount == 1 ? "" : "s") skipped."
        } else if completedCount > 0 {
            completionTitle = "Encoding finished"
            completionMessage =
                "Finished \(completedCount) \(settings.encodingWorkflow.title.lowercased()) export\(completedCount == 1 ? "" : "s")."
        } else {
            completionTitle = "Encoding finished"
            completionMessage = "No files were encoded."
        }

        setStatusMessage(completionMessage)
        notifyCompletion(completionTitle, completionMessage)
    }

    private func markJobRunning(at index: Int) -> EncodeJob {
        var updatedJobs = jobs
        updatedJobs[index].state = .running
        updatedJobs[index].message = "Encoding..."
        updatedJobs[index].diagnosticMessage = ""
        updatedJobs[index].progressFraction = nil
        updatedJobs[index].startedAt = Date()
        jobs = updatedJobs
        return updatedJobs[index]
    }

    private static func encode(
        job: EncodeJob,
        settings: EncodingSettingsSnapshot,
        progressReporter: EncodingProgressReporter?,
        processRegistry: ProcessRegistry?
    ) async -> EncodingJobResult {
        let encoder = FFmpegEncoder(
            ffmpegURL: settings.ffmpegURL,
            processRegistry: processRegistry
        )

        do {
            let output = try await encoder.encode(
                input: job.item.url,
                output: job.outputURL,
                settings: settings
            ) { progress in
                progressReporter?.report(progress)
            }
            return .success(job.id, output)
        } catch EncodeSkipError.outputExists {
            return .skipped(job.id, "Output already exists.")
        } catch is CancellationError {
            return .cancelled(job.id)
        } catch {
            return .failure(
                job.id,
                error.localizedDescription,
                failureDiagnosticMessage(for: job, settings: settings, error: error)
            )
        }
    }

    private static func failureDiagnosticMessage(
        for job: EncodeJob,
        settings: EncodingSettingsSnapshot,
        error: Error
    ) -> String {
        [
            "GPhilCoder encoding failed",
            "Input: \(job.item.url.path(percentEncoded: false))",
            "Output: \(job.outputURL.path(percentEncoded: false))",
            "FFmpeg: \(settings.ffmpegURL.path(percentEncoded: false))",
            "Settings: \(settings.summary)",
            "FFmpeg threads: \(settings.ffmpegThreads == 0 ? "Auto" : "\(settings.ffmpegThreads)")",
            "",
            "Error:",
            error.localizedDescription
        ].joined(separator: "\n")
    }

    private func apply(_ result: EncodingJobResult) {
        var updatedJobs = jobs
        guard let index = updatedJobs.firstIndex(where: { $0.id == result.jobID }) else { return }
        updatedJobs[index].finishedAt = Date()

        switch result {
        case .success(_, let output):
            updatedJobs[index].state = .succeeded
            updatedJobs[index].message = summarizeFFmpegOutput(output)
            updatedJobs[index].diagnosticMessage = ""
            updatedJobs[index].progressFraction = nil
        case .skipped(_, let message):
            updatedJobs[index].state = .skipped
            updatedJobs[index].message = message
            updatedJobs[index].diagnosticMessage = ""
            updatedJobs[index].progressFraction = nil
        case .failure(_, let message, let diagnosticMessage):
            updatedJobs[index].state = .failed
            updatedJobs[index].message = message
            updatedJobs[index].diagnosticMessage = diagnosticMessage
            updatedJobs[index].progressFraction = nil
        case .cancelled:
            updatedJobs[index].state = .cancelled
            updatedJobs[index].message = "Cancelled."
            updatedJobs[index].diagnosticMessage = ""
            updatedJobs[index].progressFraction = nil
        }

        jobs = updatedJobs
    }

    private func updateJobProgress(jobID: UUID, progress: FFmpegProgressSnapshot) {
        var updatedJobs = jobs
        guard let index = updatedJobs.firstIndex(where: { $0.id == jobID }),
            updatedJobs[index].state == .running
        else {
            return
        }
        updatedJobs[index].message = progress.message
        updatedJobs[index].progressFraction = progress.fractionCompleted
        jobs = updatedJobs
    }

    private func summarizeFFmpegOutput(_ output: String) -> String {
        let lines =
            output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return lines.last(where: { $0.contains("audio:") || $0.contains("video:") })
            ?? "Output written."
    }
}

private final class EncodingProgressReporter: @unchecked Sendable {
    private let jobID: UUID
    private let onProgress: @MainActor (UUID, FFmpegProgressSnapshot) -> Void

    init(
        jobID: UUID,
        onProgress: @escaping @MainActor (UUID, FFmpegProgressSnapshot) -> Void
    ) {
        self.jobID = jobID
        self.onProgress = onProgress
    }

    func report(_ progress: FFmpegProgressSnapshot) {
        Task { @MainActor in
            onProgress(jobID, progress)
        }
    }
}

private enum EncodingJobResult {
    case success(UUID, String)
    case skipped(UUID, String)
    case failure(UUID, String, String)
    case cancelled(UUID)

    var jobID: UUID {
        switch self {
        case .success(let id, _),
            .skipped(let id, _),
            .failure(let id, _, _),
            .cancelled(let id):
            id
        }
    }
}
