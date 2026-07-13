import AppKit
import GPhilCoderCore
import SwiftUI

struct FolderSyncWorkflowView: View {
    @EnvironmentObject private var model: EncoderViewModel
    @State private var resultsSection: FolderSyncResultsSection = .plan

    var body: some View {
        HStack(spacing: 0) {
            folderSyncSetupPanel
                .frame(width: 360)

            Divider()

            folderSyncResultsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var folderSyncSetupPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                folderSyncSetupContent
                    .padding(18)
            }

            Divider()

            folderSyncActionPanel
                .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var folderSyncSetupContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("New Pair") {
                VStack(alignment: .leading, spacing: 12) {
                    FolderPickerControl(
                        title: model.syncDraftOriginTitle,
                        detail: nil,
                        systemImage: "folder",
                        buttonTitle: "Choose origin",
                        disabled: model.isFolderSyncBusy
                    ) {
                        model.chooseSyncOriginRoot()
                    }

                    FolderPickerControl(
                        title: model.syncDraftDestinationTitle,
                        detail: nil,
                        systemImage: "externaldrive",
                        buttonTitle: "Choose destination",
                        disabled: model.isFolderSyncBusy
                    ) {
                        model.chooseSyncDestinationRoot()
                    }

                    Button {
                        model.addSyncFolderPair()
                    } label: {
                        Label(
                            model.syncFolderPairSubmitTitle,
                            systemImage: model.isEditingSyncFolderPair ? "checkmark.circle" : "plus.circle"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canAddSyncFolderPair)

                    if model.isEditingSyncFolderPair {
                        Button {
                            model.cancelEditingSyncFolderPair()
                        } label: {
                            Label("Cancel edit", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(model.isFolderSyncBusy)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Pair List") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.saveSyncFolderPairs()
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.canSaveSyncFolderPairs)

                        Button {
                            model.loadSyncFolderPairsFromFile()
                        } label: {
                            Label("Load", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.canLoadSyncFolderPairs)
                    }

                    Text("\(model.syncPairCount) sync pair\(model.syncPairCount == 1 ? "" : "s") in the current list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 11) {
                    Picker("Destination layout", selection: model.binding(\.syncDestinationLayout)) {
                        ForEach(model.syncDestinationLayoutOptions) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isFolderSyncBusy)
                    .arrowCursorOnHover()

                    Text(model.syncDestinationLayoutDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Overwrite destination files", isOn: model.binding(\.syncOverwriteExisting))
                        .disabled(model.isFolderSyncBusy)
                    Toggle(
                        "Sync deletions",
                        isOn: Binding(
                            get: { model.syncDeleteDestinationItems },
                            set: model.requestSyncDestinationDeletion
                        )
                    )
                        .disabled(model.isFolderSyncBusy)
                    Toggle("Auto-sync while app is open", isOn: model.binding(\.syncAutoSyncEnabled))
                        .disabled(model.isFolderSyncBusy)

                    Text(model.syncWatcherStatusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            if model.syncSafetyMigrationNeedsAcknowledgement {
                GroupBox("Sync Safety Update") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "Automatic sync is paused until you review the safer deletion behavior.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)

                        Text(
                            "Destination deletion used to run automatically. Automatic plans containing a deletion now pause in full for manual review."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("Turn deletion off") {
                                model.acknowledgeSyncSafetyMigration(
                                    keepDeletionEnabled: false
                                )
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Keep deletion on") {
                                model.acknowledgeSyncSafetyMigration(
                                    keepDeletionEnabled: true
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            GroupBox("File Types") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Sync files", selection: model.binding(\.syncFileFilter)) {
                        ForEach(model.syncFileFilterOptions) { filter in
                            Label(filter.title, systemImage: filter.symbolName)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isFolderSyncBusy)
                    .arrowCursorOnHover()

                    if model.syncFileFilter == .custom {
                        TextField("wav, flac, mp4", text: model.binding(\.syncCustomFileExtensions))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isFolderSyncBusy)
                    }

                    Text(model.syncFileFilterDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.syncFileFilterSummary)
                        .font(.caption)
                        .foregroundColor(model.syncHasSelectedFileTypes ? .secondary : .orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Plan") {
                VStack(alignment: .leading, spacing: 9) {
                    StatLine(
                        title: "Pairs",
                        value: "\(model.syncEnabledPairCount)/\(model.syncPairCount)",
                        symbol: "folder.badge.gearshape",
                        color: .teal
                    )
                    StatLine(
                        title: "Plan items",
                        value: "\(model.syncPendingOperationCount)",
                        symbol: "arrow.left.arrow.right",
                        color: .indigo
                    )
                    StatLine(
                        title: "To apply",
                        value: "\(model.syncPendingApplyOperationCount)",
                        symbol: "checkmark.circle",
                        color: .teal
                    )
                    StatLine(
                        title: "Copies",
                        value: "\(model.syncPendingCopyCount)",
                        symbol: "doc.on.doc",
                        color: .teal
                    )
                    StatLine(
                        title: "Deletes",
                        value: "\(model.syncPendingDeleteCount)",
                        symbol: "trash",
                        color: model.syncPendingDeleteCount > 0 ? .red : .secondary
                    )
                    if model.syncPendingSkipCount > 0 {
                        StatLine(
                            title: "Skips",
                            value: "\(model.syncPendingSkipCount)",
                            symbol: "forward.end",
                            color: .secondary
                        )
                    }
                    if model.syncPendingConflictCount > 0 {
                        StatLine(
                            title: "Conflicts",
                            value: "\(model.syncPendingConflictCount)",
                            symbol: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                    StatLine(
                        title: "Copy size",
                        value: model.syncPendingTotalSize.formattedFileSize,
                        symbol: "externaldrive",
                        color: .indigo
                    )
                }
                .padding(.vertical, 4)
            }

            if let progress = model.syncProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionCompleted)
                    HStack {
                        Text("\(progress.completed) of \(progress.total)")
                            .monospacedDigit()
                        Spacer()
                        Text("\(progress.copied) copied, \(progress.deleted) deleted")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Text(progress.copiedBytes.formattedFileSize)
                            .monospacedDigit()
                        Spacer()
                        Text(folderSyncSpeedText(for: progress))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let currentPath = progress.currentPath {
                        Text(currentPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderSyncActionPanel: some View {
        if model.isSyncRecovering {
            Label("Rolling Back...", systemImage: "arrow.uturn.backward.circle.fill")
                .frame(maxWidth: .infinity)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Folder Sync rollback in progress")
        } else if model.isFolderSyncBusy {
            Button {
                model.cancelFolderSync()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        } else {
            VStack(spacing: 10) {
                Button {
                    model.scanFolderSyncPlan()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canRunFolderSync)

                Button {
                    model.syncFoldersNow()
                } label: {
                    Label("Apply Reviewed Plan", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canApplyReviewedFolderSyncPlan)
            }
        }
    }

    private var folderSyncResultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder Sync")
                        .font(.title3.weight(.semibold))
                    Text(resultsSection == .history ? folderSyncHistorySubtitle : folderSyncSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.syncAutomaticPlanAwaitingReview {
                    FormatPill(text: "REVIEW REQUIRED")
                } else if let plan = model.syncPlan, !plan.isComplete {
                    FormatPill(text: "INCOMPLETE")
                } else if model.syncAutoSyncEnabled {
                    FormatPill(text: "AUTO")
                }
                if model.syncPendingOperationCount > 0 {
                    FormatPill(text: "\(model.syncPendingOperationCount) ITEMS")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            Picker("Folder Sync detail", selection: $resultsSection) {
                ForEach(FolderSyncResultsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .accessibilityLabel("Folder Sync detail")
            .accessibilityHint("Switches between the reviewed plan and durable history and recovery")

            Divider()

            selectedFolderSyncResultsContent
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var selectedFolderSyncResultsContent: some View {
        switch resultsSection {
        case .plan:
            folderSyncResultsContent
        case .history:
            FolderSyncHistoryView(model: model)
        }
    }

    @ViewBuilder
    private var folderSyncResultsContent: some View {
        if model.isSyncRecovering {
            CenteredStatusView(
                symbol: "arrow.uturn.backward.circle",
                title: "Rolling back folder sync",
                detail: "Restoring retained items that are still safe to recover."
            )
        } else if model.isSyncScanning {
            CenteredStatusView(
                symbol: "magnifyingglass",
                title: "Scanning folder pairs",
                detail: "Comparing origin and destination folders."
            )
        } else if model.isSyncing {
            CenteredStatusView(
                symbol: "arrow.triangle.2.circlepath",
                title: "Syncing folders",
                detail: folderSyncProgressDetail
            )
        } else if model.syncFolderPairs.isEmpty {
            CenteredStatusView(
                symbol: "folder.badge.plus",
                title: "No sync pairs",
                detail: "Choose an origin and destination folder, add the pair, then press Sync."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.syncFolderPairs) { pair in
                        SyncFolderPairRow(
                            pair: pair,
                            targetPath: model.effectiveSyncDestinationPath(for: pair),
                            isCurrent: model.currentSyncPairID == pair.id,
                            isBusy: model.isFolderSyncBusy,
                            setEnabled: { enabled in
                                model.setSyncFolderPair(pair, enabled: enabled)
                            },
                            edit: {
                                model.editSyncFolderPair(pair)
                            },
                            remove: {
                                model.removeSyncFolderPair(pair)
                            }
                        )
                    }

                    if let preview = model.syncBatchPreview,
                        !preview.groups.isEmpty || !preview.planningFailures.isEmpty
                    {
                        Divider()
                            .padding(.vertical, 4)

                        ForEach(preview.groups) { group in
                            FolderSyncPreviewPairSection(
                                group: group,
                                dispositions: model.syncPlan?.operationDispositions(
                                    overwriteExisting: model.syncOverwriteExisting
                                ) ?? [:]
                            )
                        }

                        ForEach(preview.planningFailures) { failure in
                            FolderSyncPreviewFailureSection(failure: failure)
                        }

                        if preview.hiddenOperationCount > 0 {
                            Text(
                                "\(preview.hiddenOperationCount) more change\(preview.hiddenOperationCount == 1 ? "" : "s") hidden from preview across all pairs."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                            .accessibilityLabel(
                                "\(preview.hiddenOperationCount) additional Folder Sync change\(preview.hiddenOperationCount == 1 ? "" : "s") hidden across all pairs"
                            )
                        }
                    }
                }
                .padding(18)
            }
        }
    }


    private var folderSyncSubtitle: String {
        if model.isSyncRecovering {
            return "Restoring retained items from a previous Folder Sync run."
        }
        if model.isSyncScanning {
            return "Scanning enabled folder pairs."
        }
        if model.isSyncing {
            return folderSyncProgressDetail
        }
        if model.syncPairCount == 0 {
            return "No origin-destination pairs are configured."
        }
        if model.syncEnabledPairCount == 0 {
            return "All sync pairs are paused."
        }
        if let plan = model.syncPlan, !plan.isComplete {
            let count = plan.planningFailures.count
            return
                "Incomplete preview: \(count) pair\(count == 1 ? "" : "s") could not be scanned. No changes can be applied."
        }
        if model.syncPendingOperationCount > 0 {
            return
                "\(model.syncPendingOperationCount) reviewed plan item\(model.syncPendingOperationCount == 1 ? "" : "s") across \(model.syncEnabledPairCount) enabled pair\(model.syncEnabledPairCount == 1 ? "" : "s")."
        }
        return model.syncWatcherStatusTitle
    }

    private var folderSyncHistorySubtitle: String {
        if model.syncHistory.isEmpty {
            return model.syncRecoveryRecords.isEmpty
                ? "No completed folder sync runs yet."
                : "History is empty; active recovery remains available."
        }
        return
            "\(model.syncHistory.count) recent run\(model.syncHistory.count == 1 ? "" : "s") and \(model.syncRecoveryRecords.count) active recovery record\(model.syncRecoveryRecords.count == 1 ? "" : "s")."
    }

    private var folderSyncProgressDetail: String {
        guard let progress = model.syncProgress else {
            return "Preparing folder sync."
        }
        let speedDetail = progress.bytesPerSecond
            .map { ", \($0.formattedMegabytesPerSecond)" } ?? ""
        return
            "\(progress.completed) of \(progress.total) processed, \(progress.copied) copied, \(progress.deleted) deleted, \(progress.failed) failed\(speedDetail)."
    }

    private func folderSyncSpeedText(for progress: FolderSyncProgress) -> String {
        progress.bytesPerSecond?.formattedMegabytesPerSecond ?? "Calculating speed"
    }
}

private struct SyncFolderPairRow: View {
    let pair: SyncFolderPair
    let targetPath: String
    let isCurrent: Bool
    let isBusy: Bool
    let setEnabled: (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void

    private var stateColor: Color {
        switch pair.state {
        case .succeeded, .watching:
            .green
        case .syncing:
            .teal
        case .failed:
            .orange
        case .disabled:
            .secondary
        case .idle:
            .indigo
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: pair.state.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(stateColor)
            .frame(width: 34, height: 34)
            .background(
                stateColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(pair.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(pair.state.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            stateColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    Spacer()

                    Toggle("", isOn: Binding(get: { pair.isEnabled }, set: setEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isBusy)

                    Button {
                        edit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.gphilHoverBorderless)
                    .disabled(isBusy)
                    .help("Edit sync pair")

                    Button(role: .destructive) {
                        remove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.gphilHoverBorderless)
                    .disabled(isBusy)
                    .help("Remove sync pair")
                }

                Text(pair.originPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pair.destinationPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Target: \(targetPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(pair.lastMessage)
                        .font(.caption)
                        .foregroundStyle(pair.state == .failed ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let lastSyncedAt = pair.lastSyncedAt {
                        Text(lastSyncedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(stateColor.opacity(isCurrent ? 0.65 : 0.35))
        }
    }
}

private struct FolderSyncOperationRow: View {
    let batchOperation: FolderSyncBatchOperation
    let disposition: FolderSyncBatchOperationDisposition

    private var operation: FolderSyncOperation { batchOperation.operation }

    private var color: Color {
        if disposition == .conflict { return .orange }
        if disposition == .skipExisting { return .secondary }
        switch operation.kind {
        case .copyNew, .copyUpdated, .createDirectory:
            return .teal
        case .deleteFile, .deleteDirectory:
            return .red
        }
    }

    private var symbolName: String {
        if disposition == .conflict { return "exclamationmark.triangle" }
        if disposition == .skipExisting { return "forward.end" }
        switch operation.kind {
        case .createDirectory:
            return "folder.badge.plus"
        case .copyNew:
            return "doc.badge.plus"
        case .copyUpdated:
            return "arrow.clockwise"
        case .deleteFile:
            return "trash"
        case .deleteDirectory:
            return "folder.badge.minus"
        }
    }

    private var title: String {
        if disposition == .conflict { return "Conflict" }
        if disposition == .skipExisting { return "Skip existing" }
        switch operation.kind {
        case .createDirectory:
            return "Create folder"
        case .copyNew:
            return "Copy new"
        case .copyUpdated:
            return "Update"
        case .deleteFile:
            return "Delete file"
        case .deleteDirectory:
            return "Delete folder"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(
                    color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(operation.relativePath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            color.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    Spacer()

                    if operation.fileSizeBytes > 0 {
                        Text(operation.fileSizeBytes.formattedFileSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(operation.destinationURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if disposition == .conflict {
                    Text("A file/folder type mismatch blocks this item until it is resolved.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if disposition == .skipExisting {
                    Text("Overwrite is off, so the existing destination item will be kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.35))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(operation.relativePath), destination \(operation.destinationURL.path(percentEncoded: false))"
        )
    }
}

private struct FolderSyncPreviewPairSection: View {
    let group: FolderSyncPairPreview
    let dispositions: [FolderSyncBatchOperationKey: FolderSyncBatchOperationDisposition]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Label(group.pairTitle, systemImage: "folder.badge.gearshape")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.teal)

                    Spacer()

                    Text(
                        group.hiddenOperationCount > 0
                            ? "\(group.visibleOperationCount) of \(group.totalOperationCount) shown"
                            : "\(group.totalOperationCount) change\(group.totalOperationCount == 1 ? "" : "s")"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                Text("Origin: \(group.originRoot.path(percentEncoded: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Destination: \(group.destinationRoot.path(percentEncoded: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Pair \(group.pairTitle). Origin \(group.originRoot.path(percentEncoded: false)). Destination \(group.destinationRoot.path(percentEncoded: false)). \(group.visibleOperationCount) of \(group.totalOperationCount) changes shown, \(group.hiddenOperationCount) hidden."
            )

            ForEach(group.operations) { operation in
                FolderSyncOperationRow(
                    batchOperation: operation,
                    disposition: dispositions[operation.key] ?? .apply
                )
            }

            if group.hiddenOperationCount > 0 {
                Text(
                    "\(group.hiddenOperationCount) more change\(group.hiddenOperationCount == 1 ? "" : "s") hidden for this pair."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FolderSyncPreviewFailureSection: View {
    let failure: FolderSyncPairPlanningFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Scan failed: \(failure.pairTitle)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)

            Text("Origin: \(failure.originRoot.path(percentEncoded: false))")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Destination: \(failure.destinationRoot.path(percentEncoded: false))")
                .lineLimit(1)
                .truncationMode(.middle)
            Text(failure.errorDescription)
                .foregroundStyle(.red)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Folder Sync scan failed for pair \(failure.pairTitle). Origin \(failure.originRoot.path(percentEncoded: false)). Destination \(failure.destinationRoot.path(percentEncoded: false)). Error: \(failure.errorDescription). This incomplete plan cannot be applied."
        )
    }
}
