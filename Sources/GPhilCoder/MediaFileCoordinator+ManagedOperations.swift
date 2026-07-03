import Foundation
import GPhilCoderCore

@MainActor
extension MediaFileCoordinator {
    func deleteFilteredFiles() {
        guard fileManagementMode == .delete else { return }

        guard let plan = mediaDeletePlan, plan.hasDeletableContent else {
            setStatusMessage("No filtered delete preview is ready yet.")
            refreshDeletePreviewIfNeeded(configuration: mediaPreviewConfiguration)
            return
        }

        let configuration = mediaPreviewConfiguration
        guard deletePlan(plan, matches: configuration) else {
            setStatusMessage("Refresh the delete preview before moving files to Trash.")
            refreshDeletePreviewIfNeeded(configuration: configuration)
            return
        }

        let fullPlan = MediaCopyPlanner.buildDeletePlan(
            sourceRoots: plan.sourceRoots,
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter,
            inventory: mediaFileInventory
        )
        guard fullPlan.hasDeletableContent else {
            setStatusMessage("No filtered files are available to move to Trash.")
            mediaDeletePlan = fullPlan
            return
        }

        let items = fullPlan.candidates.map { TrashableFileItem(deleteCandidate: $0) }
        guard promptTrash(
            items.count,
            fullPlan.totalSizeBytes,
            fullPlan.sourceRoots.count,
            fullPlan.filter,
            fullPlan.selectedExtensions,
            fullPlan.fileNameFilter
        ) else {
            setStatusMessage("Filtered delete cancelled.")
            return
        }

        let pendingRecordsByItemID: [UUID: PendingTrashSourceRecord]
        do {
            pendingRecordsByItemID = try recordPendingTrashIntents(items)
        } catch {
            setStatusMessage(
                "Could not save emergency trash journal. Nothing moved to Trash: \(error.localizedDescription)"
            )
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = true
        isMediaRenaming = false
        let progressStartedAt = Date()
        setProgress(
            MediaCopyProgress(
                completed: 0,
                total: items.count,
                copied: 0,
                skippedExisting: 0,
                failed: 0,
                copiedBytes: 0,
                totalBytes: fullPlan.totalSizeBytes,
                startedAt: progressStartedAt,
                updatedAt: progressStartedAt,
                currentName: nil
            )
        )
        setStatusMessage(
            "Moving \(items.count) filtered file\(items.count == 1 ? "" : "s") to Trash..."
        )

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await moveTrashableItemsToTrash(
                items,
                pendingRecordsByItemID: pendingRecordsByItemID
            )

            guard !Task.isCancelled else { return }

            isMediaDeleting = false
            mediaCopyTask = nil
            let completionMessage = Self.mediaTrashResultStatusMessage(
                result,
                filter: fullPlan.filter,
                selectedExtensions: fullPlan.selectedExtensions,
                fileNameFilter: fullPlan.fileNameFilter
            )
            setStatusMessage(completionMessage)
            notifyCompletion("Filtered delete finished", completionMessage)
        }
    }

    func renameFilteredFiles() {
        guard fileManagementMode == .rename else { return }

        guard let plan = mediaRenamePlan else {
            setStatusMessage("No rename preview is ready yet.")
            refreshRenamePreviewIfNeeded(configuration: mediaPreviewConfiguration)
            return
        }

        guard !isMediaRenamePreviewStale else {
            setStatusMessage("Refresh the rename preview before applying these settings.")
            return
        }

        let fullPlan = MediaCopyPlanner.buildRenamePlan(
            sourceRoots: plan.sourceRoots,
            filter: plan.filter,
            selectedExtensions: plan.selectedExtensions,
            fileNameFilter: plan.fileNameFilter,
            settings: plan.settings,
            inventory: mediaFileInventory
        )

        guard fullPlan.blockedCount == 0 else {
            setStatusMessage(
                "Resolve \(fullPlan.blockedCount) rename conflict\(fullPlan.blockedCount == 1 ? "" : "s") before applying."
            )
            mediaRenamePlan = fullPlan
            return
        }

        let items = fullPlan.readyItems
        guard !items.isEmpty else {
            setStatusMessage("No files need renaming.")
            mediaRenamePlan = fullPlan
            return
        }

        guard promptRename(items.count, fullPlan.unchangedCount) else {
            setStatusMessage("Rename cancelled.")
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = true
        mediaRenameProgressVerb = "renamed"
        let progressStartedAt = Date()
        setProgress(
            MediaCopyProgress(
                completed: 0,
                total: items.count,
                copied: 0,
                skippedExisting: fullPlan.unchangedCount,
                failed: 0,
                copiedBytes: 0,
                totalBytes: fullPlan.totalSizeBytes,
                startedAt: progressStartedAt,
                updatedAt: progressStartedAt,
                currentName: nil
            )
        )
        setStatusMessage("Renaming \(items.count) file\(items.count == 1 ? "" : "s")...")

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await renameMediaItems(items, unchangedCount: fullPlan.unchangedCount)

            guard !Task.isCancelled else { return }

            isMediaRenaming = false
            mediaCopyTask = nil
            if !result.historyItems.isEmpty {
                pushMediaRenameUndoTransaction(
                    MediaRenameHistoryTransaction(
                        actionTitle: plan.settings.operation.title,
                        items: result.historyItems
                    )
                )
                mediaRenameRedoStack.removeAll()
            }
            let completionMessage = Self.mediaRenameResultStatusMessage(result)
            setStatusMessage(completionMessage)
            notifyCompletion("Rename finished", completionMessage)
        }
    }

    func runRenameHistoryAction(_ direction: MediaRenameHistoryDirection) {
        guard fileManagementMode == .rename else { return }

        let transaction: MediaRenameHistoryTransaction?
        switch direction {
        case .undo:
            transaction = mediaRenameUndoStack.last
        case .redo:
            transaction = mediaRenameRedoStack.last
        }

        guard let transaction, !transaction.items.isEmpty else {
            setStatusMessage("No rename action to \(direction == .undo ? "undo" : "redo").")
            return
        }

        guard promptRenameHistory(transaction, direction) else {
            setStatusMessage("\(direction.title) cancelled.")
            return
        }

        mediaCopyTask?.cancel()
        mediaCopyProgress = nil
        isMediaCopyScanning = false
        isMediaCopying = false
        isMediaDeleting = false
        isMediaRenaming = true
        mediaRenameProgressVerb = direction.progressVerb
        let progressStartedAt = Date()
        setProgress(
            MediaCopyProgress(
                completed: 0,
                total: transaction.items.count,
                copied: 0,
                skippedExisting: 0,
                failed: 0,
                copiedBytes: 0,
                totalBytes: transaction.items.reduce(Int64(0)) { $0 + $1.fileSizeBytes },
                startedAt: progressStartedAt,
                updatedAt: progressStartedAt,
                currentName: nil
            )
        )
        setStatusMessage(
            "\(direction.progressTitle) for \(transaction.items.count) file\(transaction.items.count == 1 ? "" : "s")..."
        )

        mediaCopyTask = Task { [weak self] in
            guard let self else { return }
            let result = await applyMediaRenameHistoryTransaction(
                transaction,
                direction: direction
            )

            guard !Task.isCancelled else { return }

            isMediaRenaming = false
            mediaCopyTask = nil
            completeRenameHistoryAction(transaction, direction, result)
            moveMediaInventoryRecords(result.movedItems, direction: direction)
            mediaRenamePlan = nil
            isMediaRenamePreviewStale = false
            let completionMessage = Self.mediaRenameHistoryResultStatusMessage(
                result,
                direction: direction
            )
            setStatusMessage(completionMessage)
            notifyCompletion(direction.notificationTitle, completionMessage)
        }
    }

    func cancelFileNameFilterRefresh() {
        mediaFileNameFilterRefreshTask?.cancel()
        mediaFileNameFilterRefreshTask = nil
    }

    func scheduleFileNameFilterPreviewRefresh(
        nanoseconds: UInt64,
        refresh: @escaping @MainActor () -> Void,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        cancelFileNameFilterRefresh()
        mediaFileNameFilterRefreshTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isBusy() else { return }
                refresh()
            }
        }
    }

    private func moveTrashableItemsToTrash(
        _ items: [TrashableFileItem],
        pendingRecordsByItemID: [UUID: PendingTrashSourceRecord]
    ) async -> MediaTrashResult {
        var result = MediaTrashResult(total: items.count)
        let progressStartedAt = Date()
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var movedBytes: Int64 = 0
        var movedPaths = Set<String>()

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            setProgress(
                MediaCopyProgress(
                    completed: index,
                    total: items.count,
                    copied: result.moved,
                    skippedExisting: 0,
                    failed: result.failed,
                    copiedBytes: movedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: item.name
                )
            )

            guard let pendingRecord = pendingRecordsByItemID[item.id] else {
                result.failed += 1
                result.failedNames.append(item.name)
                continue
            }

            do {
                let moveResult = try moveTrashItemAndRecord(item, pendingRecord)
                result.moved += 1
                movedBytes += item.fileSizeBytes
                movedPaths.insert(item.url.standardizedFileURL.path)
                if moveResult == .restoreLedgerRecorded {
                    try? removePendingTrashRecords([pendingRecord.id])
                } else {
                    result.emergencyOnly += 1
                }
            } catch {
                removePendingTrashRecordIfOriginalStillExists(pendingRecord)
                result.failed += 1
                result.failedNames.append(item.name)
            }

            let progress = MediaCopyProgress(
                completed: index + 1,
                total: items.count,
                copied: result.moved,
                skippedExisting: 0,
                failed: result.failed,
                copiedBytes: movedBytes,
                totalBytes: totalBytes,
                startedAt: progressStartedAt,
                updatedAt: Date(),
                currentName: item.name
            )
            mediaCopyProgress = progress
            let speedDetail = progress.bytesPerSecond
                .map { " at \($0.formattedMegabytesPerSecond)" } ?? ""
            setStatusMessage(
                "Moved \(result.moved), failed \(result.failed) of \(items.count) to Trash\(speedDetail)."
            )
        }

        if !movedPaths.isEmpty {
            removeInputsAndResetJobs(movedPaths)
            removeMediaInventoryRecords(matching: movedPaths)
            if let mediaDeletePlan = mediaDeletePlan {
                self.mediaDeletePlan = MediaDeletePlan(
                    sourceRoots: mediaDeletePlan.sourceRoots,
                    filter: mediaDeletePlan.filter,
                    selectedExtensions: mediaDeletePlan.selectedExtensions,
                    fileNameFilter: mediaDeletePlan.fileNameFilter,
                    candidates: mediaDeletePlan.candidates.filter {
                        !movedPaths.contains($0.sourceURL.standardizedFileURL.path)
                    },
                    candidateCount: max(0, mediaDeletePlan.candidateCount - movedPaths.count),
                    totalSizeBytes: max(0, mediaDeletePlan.totalSizeBytes - movedBytes),
                    scannedAt: Date()
                )
            }
        }

        return result
    }

    private func renameMediaItems(
        _ items: [MediaRenameItem],
        unchangedCount: Int
    ) async -> MediaRenameResult {
        var result = MediaRenameResult(total: items.count)
        let progressStartedAt = Date()
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var renamedBytes: Int64 = 0
        var renamedSourcePaths = Set<String>()

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            setProgress(
                MediaCopyProgress(
                    completed: index,
                    total: items.count,
                    copied: result.renamed,
                    skippedExisting: unchangedCount,
                    failed: result.failed,
                    copiedBytes: renamedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: item.originalName
                )
            )

            let renameSucceeded = await Task.detached(priority: .userInitiated) {
                do {
                    try moveRenameFile(from: item.sourceURL, to: item.targetURL)
                    return true
                } catch {
                    return false
                }
            }.value

            if renameSucceeded {
                result.renamed += 1
                renamedBytes += item.fileSizeBytes
                renamedSourcePaths.insert(item.sourceURL.standardizedFileURL.path)
                result.historyItems.append(
                    MediaRenameHistoryItem(
                        originalPath: item.sourceURL.standardizedFileURL.path,
                        renamedPath: item.targetURL.standardizedFileURL.path,
                        originalName: item.originalName,
                        renamedName: item.newName,
                        fileSizeBytes: item.fileSizeBytes
                    )
                )
            } else {
                result.failed += 1
                result.failedNames.append(item.originalName)
            }

            setProgress(
                MediaCopyProgress(
                    completed: index + 1,
                    total: items.count,
                    copied: result.renamed,
                    skippedExisting: unchangedCount,
                    failed: result.failed,
                    copiedBytes: renamedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: item.originalName
                )
            )
            setStatusMessage(
                "Renamed \(result.renamed), failed \(result.failed) of \(items.count)."
            )
        }

        if !renamedSourcePaths.isEmpty {
            moveMediaInventoryRecords(result.historyItems, direction: .redo)
            if let mediaRenamePlan = mediaRenamePlan {
                let remainingItems = mediaRenamePlan.items.filter {
                    !renamedSourcePaths.contains($0.sourceURL.standardizedFileURL.path)
                }
                self.mediaRenamePlan = MediaRenamePlan(
                    sourceRoots: mediaRenamePlan.sourceRoots,
                    filter: mediaRenamePlan.filter,
                    selectedExtensions: mediaRenamePlan.selectedExtensions,
                    fileNameFilter: mediaRenamePlan.fileNameFilter,
                    settings: mediaRenamePlan.settings,
                    items: remainingItems,
                    itemCount: max(0, mediaRenamePlan.itemCount - renamedSourcePaths.count),
                    totalSizeBytes: max(0, mediaRenamePlan.totalSizeBytes - renamedBytes),
                    readyCount: remainingItems.filter { $0.state == .ready }.count,
                    blockedCount: mediaRenamePlan.blockedCount,
                    unchangedCount: mediaRenamePlan.unchangedCount,
                    scannedAt: Date()
                )
            }
            resetJobsForMediaMutation()
        }

        return result
    }

    private func applyMediaRenameHistoryTransaction(
        _ transaction: MediaRenameHistoryTransaction,
        direction: MediaRenameHistoryDirection
    ) async -> MediaRenameHistoryResult {
        var result = MediaRenameHistoryResult(total: transaction.items.count)
        let progressStartedAt = Date()
        let totalBytes = transaction.items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var movedBytes: Int64 = 0

        for (index, item) in transaction.items.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }

            let sourceURL: URL
            let targetURL: URL
            let currentName: String
            switch direction {
            case .undo:
                sourceURL = URL(fileURLWithPath: item.renamedPath)
                targetURL = URL(fileURLWithPath: item.originalPath)
                currentName = item.renamedName
            case .redo:
                sourceURL = URL(fileURLWithPath: item.originalPath)
                targetURL = URL(fileURLWithPath: item.renamedPath)
                currentName = item.originalName
            }

            setProgress(
                MediaCopyProgress(
                    completed: index,
                    total: transaction.items.count,
                    copied: result.moved,
                    skippedExisting: 0,
                    failed: result.failed,
                    copiedBytes: movedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: currentName
                )
            )

            let moveSucceeded = await Task.detached(priority: .userInitiated) {
                do {
                    try moveRenameFile(from: sourceURL, to: targetURL)
                    return true
                } catch {
                    return false
                }
            }.value

            if moveSucceeded {
                result.moved += 1
                movedBytes += item.fileSizeBytes
                result.movedItems.append(item)
            } else {
                result.failed += 1
                result.failedNames.append(currentName)
            }

            setProgress(
                MediaCopyProgress(
                    completed: index + 1,
                    total: transaction.items.count,
                    copied: result.moved,
                    skippedExisting: 0,
                    failed: result.failed,
                    copiedBytes: movedBytes,
                    totalBytes: totalBytes,
                    startedAt: progressStartedAt,
                    updatedAt: Date(),
                    currentName: currentName
                )
            )
            setStatusMessage(
                "\(direction.progressTitle): \(result.moved) \(direction.progressVerb), \(result.failed) failed of \(transaction.items.count)."
            )
        }

        if result.moved > 0 {
            resetJobsForMediaMutation()
        }

        return result
    }

    private func removeMediaInventoryRecords(matching paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let nextInventory = mediaFileInventory.filter {
            !paths.contains($0.sourceURL.standardizedFileURL.path)
        }
        setInventory(nextInventory, mediaFileInventorySourceRootPaths)
    }

    private func moveMediaInventoryRecords(
        _ items: [MediaRenameHistoryItem],
        direction: MediaRenameHistoryDirection
    ) {
        var inventory = mediaFileInventory
        guard !items.isEmpty, !inventory.isEmpty else { return }

        for item in items {
            let sourcePath: String
            let targetPath: String
            switch direction {
            case .undo:
                sourcePath = item.renamedPath
                targetPath = item.originalPath
            case .redo:
                sourcePath = item.originalPath
                targetPath = item.renamedPath
            }

            guard let index = inventory.firstIndex(where: {
                $0.sourceURL.standardizedFileURL.path == sourcePath
            }) else {
                continue
            }

            let record = inventory[index]
            let targetURL = URL(fileURLWithPath: targetPath)
            let relativePath: String
            if let relativeDirectory = record.relativeDirectory {
                relativePath = "\(relativeDirectory)/\(targetURL.lastPathComponent)"
            } else {
                relativePath = targetURL.lastPathComponent
            }

            inventory[index] = MediaFileInventoryRecord(
                id: targetURL.standardizedFileURL.path,
                sourceURL: targetURL,
                sourceRoot: record.sourceRoot,
                relativePath: relativePath,
                fileSizeBytes: record.fileSizeBytes,
                modifiedDate: record.modifiedDate
            )
        }

        inventory.sort {
            $0.sourceURL.path.localizedCaseInsensitiveCompare($1.sourceURL.path)
                == .orderedAscending
        }
        setInventory(inventory, mediaFileInventorySourceRootPaths)
    }

    private func deletePlan(
        _ plan: MediaDeletePlan,
        matches configuration: MediaPreviewConfiguration
    ) -> Bool {
        plan.sourceRoots.map { $0.standardizedFileURL.path }
            == configuration.sourceRoots.map { $0.standardizedFileURL.path }
            && plan.filter == configuration.filter
            && plan.selectedExtensions == (configuration.selectedExtensions ?? [])
            && plan.fileNameFilter == configuration.fileNameFilter
    }

    private static func mediaTrashResultStatusMessage(
        _ result: MediaTrashResult,
        filter: MediaFileFilter,
        selectedExtensions: Set<String>,
        fileNameFilter: MediaFileNameFilter
    ) -> String {
        if result.cancelled {
            return "Filtered delete cancelled after \(result.moved) moved file\(result.moved == 1 ? "" : "s")."
        }

        var details = [
            "Moved \(result.moved) file\(result.moved == 1 ? "" : "s") matching \(mediaDeleteScopeDescription(filter: filter, selectedExtensions: selectedExtensions, fileNameFilter: fileNameFilter)) to Trash."
        ]
        if result.emergencyOnly > 0 {
            details.append(
                "\(result.emergencyOnly) restore path\(result.emergencyOnly == 1 ? "" : "s") kept in the emergency journal because macOS did not return a Trash path."
            )
        }
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    private static func mediaRenameResultStatusMessage(
        _ result: MediaRenameResult
    ) -> String {
        if result.cancelled {
            return "Rename cancelled after \(result.renamed) renamed file\(result.renamed == 1 ? "" : "s")."
        }

        var details = [
            "Renamed \(result.renamed) file\(result.renamed == 1 ? "" : "s")."
        ]
        if result.failed > 0 {
            details.append(
                "Failed \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }

    private static func mediaRenameHistoryResultStatusMessage(
        _ result: MediaRenameHistoryResult,
        direction: MediaRenameHistoryDirection
    ) -> String {
        if result.cancelled {
            return "\(direction.title) cancelled after \(result.moved) file\(result.moved == 1 ? "" : "s") \(direction.progressVerb)."
        }

        var details = [
            "\(direction.title) complete: \(result.moved) file\(result.moved == 1 ? "" : "s") \(direction.progressVerb)."
        ]
        if result.failed > 0 {
            details.append(
                "Skipped \(result.failed): \(result.failedNames.prefix(3).joined(separator: ", "))\(result.failedNames.count > 3 ? "..." : "")."
            )
        }
        return details.joined(separator: " ")
    }
}
