import Foundation
import GPhilCoderCore

@MainActor
extension EncoderViewModel {
    func addCurrentMediaCopyWorkflowToQueue() {
        guard let destinationRoot = mediaCopyDestinationRoot,
            canAddMediaCopyWorkflowToQueue
        else {
            statusMessage = "Choose source and destination folders before adding to the queue."
            return
        }

        for sourceRoot in mediaCopySourceRoots {
            let resolvedDestination = mediaCopyDestinationLayout.resolvedDestinationRoot(
                for: sourceRoot,
                destinationRoot: destinationRoot
            )
            guard validateMediaCopyFolders(
                sourceRoot: sourceRoot,
                destinationRoot: resolvedDestination
            )
            else {
                return
            }
        }

        let workflow = MediaCopyWorkflow(
            sourceRoots: mediaCopySourceRoots,
            destinationRoot: destinationRoot,
            destinationLayout: mediaCopyDestinationLayout,
            filter: mediaCopyFilter,
            selectedExtensions: mediaFileCoordinator.selectedExtensions(for: mediaCopyFilter),
            fileNameFilter: mediaFileCoordinator.currentMediaFileNameFilter
        )
        mediaCopyQueue.append(workflow)
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        statusMessage =
            "Added one workflow with \(workflow.sourceRoots.count) source folder\(workflow.sourceRoots.count == 1 ? "" : "s") to the file copy queue."
    }

    func removeMediaCopyWorkflowFromQueue(_ workflow: MediaCopyWorkflow) {
        guard !isMediaCopyBusy else { return }
        mediaCopyQueue.removeAll { $0.id == workflow.id }
        statusMessage =
            mediaCopyQueue.isEmpty
            ? "File copy queue cleared."
            : "Removed queued workflow. \(mediaCopyQueue.count) remaining."
    }

    func clearMediaCopyQueue() {
        guard !isMediaCopyBusy else { return }
        mediaCopyQueue.removeAll()
        currentMediaCopyWorkflowID = nil
        statusMessage = "File copy queue cleared."
    }

    func repairMediaCopyWorkflow(_ workflow: MediaCopyWorkflow) {
        guard !isMediaCopyBusy,
            let workflowIndex = mediaCopyQueue.firstIndex(where: { $0.id == workflow.id })
        else {
            return
        }

        var repaired = workflow
        for issue in workflow.repairIssues {
            let missingURL = issue.url
            guard let replacement = MediaCopyAppKitBoundary.chooseRepairDirectory(
                for: missingURL
            ) else {
                statusMessage = "File copy workflow repair cancelled."
                return
            }

            switch issue {
            case .missingSource(let sourceRoot):
                repaired = repaired.replacingSourceRoot(sourceRoot, with: replacement)
            case .missingDestination:
                repaired = repaired.replacingDestinationRoot(with: replacement)
            }
        }

        for sourceRoot in repaired.sourceRoots {
            let resolvedDestination = repaired.destinationLayout.resolvedDestinationRoot(
                for: sourceRoot,
                destinationRoot: repaired.destinationRoot
            )
            guard validateMediaCopyFolders(
                sourceRoot: sourceRoot,
                destinationRoot: resolvedDestination
            ) else {
                return
            }
        }

        mediaCopyQueue[workflowIndex] = repaired
        statusMessage = "Repaired queued file copy workflow."
    }

    func saveMediaCopyJob() {
        guard canSaveMediaCopyJob else {
            statusMessage = "Add workflows to the file copy queue before saving a job."
            return
        }

        guard let selectedURL = MediaCopyAppKitBoundary.chooseSaveJobURL(
            initialDirectory: mediaCopyDestinationRoot
                ?? primaryMediaCopySourceRoot
                ?? lastInputDirectoryURL(),
            defaultName: defaultMediaCopyJobFileName()
        ) else { return }

        let url = normalizedMediaCopyJobFileURL(selectedURL)
        let document = MediaCopyJobDocument(workflows: mediaCopyQueue)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            statusMessage =
                "Saved file copy job with \(mediaCopyQueue.count) workflow\(mediaCopyQueue.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not save file copy job: \(error.localizedDescription)"
        }
    }

    func loadMediaCopyJob() {
        guard !isMediaCopyBusy else { return }

        guard let url = MediaCopyAppKitBoundary.chooseLoadJobURL(
            initialDirectory: mediaCopyDestinationRoot
                ?? primaryMediaCopySourceRoot
                ?? lastInputDirectoryURL()
        ) else { return }

        do {
            let data = try Data(contentsOf: url)
            try loadMediaCopyJobData(data)
        } catch {
            statusMessage = "Could not load file copy job: \(error.localizedDescription)"
        }
    }

    func loadMediaCopyJobData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MediaCopyJobDocument.self, from: data)
        replaceMediaCopyQueue(with: document.workflows)
    }

    func replaceMediaCopyQueue(with workflows: [MediaCopyWorkflow]) {
        mediaCopyQueue = workflows
        mediaCopyPlan = nil
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil

        var details = [
            "Loaded \(workflows.count) file copy workflow\(workflows.count == 1 ? "" : "s")."
        ]
        let repairCount = workflows.filter { !$0.repairIssues.isEmpty }.count
        if repairCount > 0 {
            details.append(
                "\(repairCount) workflow\(repairCount == 1 ? " needs" : "s need") folder repair before running."
            )
        }
        statusMessage = details.joined(separator: " ")
    }

    func runMediaCopyQueue() {
        guard canRunMediaCopyQueue else {
            if mediaCopyQueueRepairCount > 0 {
                statusMessage = "Repair missing source or destination folders before running the queue."
            }
            return
        }

        for workflow in mediaCopyQueue {
            for sourceRoot in workflow.sourceRoots {
                let resolvedDestination = workflow.destinationLayout.resolvedDestinationRoot(
                    for: sourceRoot,
                    destinationRoot: workflow.destinationRoot
                )
                guard validateMediaCopyFolders(
                    sourceRoot: sourceRoot,
                    destinationRoot: resolvedDestination
                ) else {
                    return
                }
            }
        }

        mediaFileCoordinator.runQueuedWorkflows(mediaCopyQueue)
    }

    func cancelMediaCopy() {
        guard canCancelMediaCopy else { return }
        mediaFileCoordinator.cancel()
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = false
        mediaRenameProgressVerb = "renamed"
        mediaCopyProgress = nil
        currentMediaCopyWorkflowID = nil
        statusMessage = "File management operation cancelled."
    }

    private func defaultMediaCopyJobFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhil MediaFlow File Copy \(formatter.string(from: Date())).\(MediaCopyJobFile.fileExtension)"
    }

    private func normalizedMediaCopyJobFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(MediaCopyJobFile.fileExtension) : url
    }
}
