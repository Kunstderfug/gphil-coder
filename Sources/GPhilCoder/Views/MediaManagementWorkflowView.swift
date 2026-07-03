import AppKit
import GPhilCoderCore
import SwiftUI

struct MediaManagementWorkflowView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: EncoderViewModel
    let mode: FileManagementMode
    @Binding var selectedMediaCopyPreviewMode: MediaCopyPreviewMode

    var body: some View {
        HStack(spacing: 0) {
            mediaCopySetupPanel
                .frame(width: 340)

            Divider()

            mediaCopyResultsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.fileManagementMode = mode
            if mode == .copy {
                selectedMediaCopyPreviewMode = .plan
            }
        }
    }

    private var mediaCopySetupPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Source") {
                        FolderPickerControl(
                            title: model.mediaCopySourceSummary,
                            detail: model.mediaCopySourceDetail,
                            systemImage: "folder.badge.plus",
                            buttonTitle: "Choose sources",
                            disabled: model.isMediaCopyBusy,
                            secondaryButtonTitle: "Clear",
                            secondarySystemImage: "xmark.circle",
                            secondaryDisabled: !model.canClearMediaCopySources
                        ) {
                            model.chooseMediaCopySourceRoot()
                        } secondaryAction: {
                            model.clearMediaCopySources()
                        }
                        .padding(.vertical, 4)
                    }

                    if model.fileManagementMode == .copy {
                        GroupBox("Destination") {
                            FolderPickerControl(
                                title: model.mediaCopyDestinationRoot?.path(percentEncoded: false)
                                    ?? "No destination folder selected",
                                detail: nil,
                                systemImage: "externaldrive",
                                buttonTitle: "Choose destination",
                                disabled: model.isMediaCopyBusy
                            ) {
                                model.chooseMediaCopyDestinationRoot()
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    GroupBox("Filter") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Media type", selection: model.binding(\.mediaCopyFilter)) {
                                ForEach(model.availableMediaFileFilters) { filter in
                                    Label(filter.title, systemImage: filter.symbolName)
                                        .tag(filter)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(model.isMediaCopyBusy)
                            .arrowCursorOnHover()

                            if model.mediaCopyFilter.supportsExtensionSelection {
                                Menu {
                                    Button {
                                        model.selectAllMediaCopyExtensions()
                                    } label: {
                                        Label("Select all", systemImage: "checklist.checked")
                                    }

                                    Button {
                                        model.deselectAllMediaCopyExtensions()
                                    } label: {
                                        Label("Deselect all", systemImage: "checklist.unchecked")
                                    }

                                    Divider()

                                    ForEach(model.mediaCopyExtensionOptions, id: \.self) { fileExtension in
                                        Toggle(
                                            ".\(fileExtension)",
                                            isOn: Binding(
                                                get: { model.isMediaCopyExtensionEnabled(fileExtension) },
                                                set: { model.setMediaCopyExtension(fileExtension, enabled: $0) }
                                            )
                                        )
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(model.mediaCopyExtensionMenuTitle)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .disabled(model.isMediaCopyBusy)
                                .help("Choose the exact file extensions for this filter")
                            }

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Name")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .trailing)

                                TextField("Any file name", text: model.binding(\.mediaFileNameFilterQuery))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(model.isMediaCopyBusy)
                                    .help("Match files whose names contain this text")
                            }

                            Text(model.mediaCopySelectedExtensionSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(model.mediaFileNameFilterSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    if model.fileManagementMode == .rename {
                        mediaRenameSummaryGroup
                    }

                    GroupBox("Plan") {
                        VStack(alignment: .leading, spacing: 9) {
                            mediaPlanSummaryLines
                        }
                        .padding(.vertical, 4)
                    }

                    if let progress = model.mediaCopyProgress {
                        mediaProgressPanel(progress)
                    }

                    if model.fileManagementMode == .copy {
                        mediaCopyQueueGroup
                    }
                }
                .padding(18)
            }

            Divider()

            mediaManagementActions
                .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var mediaRenameSummaryGroup: some View {
        GroupBox("Rename") {
            VStack(alignment: .leading, spacing: 10) {
                StatLine(
                    title: "Action",
                    value: model.mediaRenameOperation.title,
                    symbol: "textformat",
                    color: .teal
                )
                StatLine(
                    title: "Sort",
                    value: model.mediaRenameSort.title,
                    symbol: "arrow.up.arrow.down",
                    color: .indigo
                )

                Button {
                    openWindow(id: AppWindowID.renameSettings)
                } label: {
                    Label("Open settings", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isMediaCopyBusy)
                .help("Open rename settings in a separate window")
            }
            .padding(.vertical, 4)
        }
    }

    private var mediaCopyResultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activeMediaPlanTitle)
                        .font(.title3.weight(.semibold))
                    Text(mediaCopySubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.fileManagementMode == .copy {
                    Picker("", selection: $selectedMediaCopyPreviewMode) {
                        Text("Plan").tag(MediaCopyPreviewMode.plan)
                        Text("Queue").tag(MediaCopyPreviewMode.queue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .labelsHidden()
                    .disabled(model.isMediaCopyBusy)
                    .arrowCursorOnHover()
                }

                if model.fileManagementMode == .rename,
                    let plan = model.mediaRenamePlan,
                    plan.hasRenameContent
                {
                    HStack(spacing: 8) {
                        FormatPill(text: plan.settings.operation.title.uppercased())
                        if model.isMediaRenamePreviewStale {
                            FormatPill(text: "STALE")
                        }
                        FormatPill(text: "\(plan.readyCount) READY")
                        if plan.blockedCount > 0 {
                            FormatPill(text: "\(plan.blockedCount) BLOCKED")
                        }
                    }
                } else if model.fileManagementMode == .delete,
                    let plan = model.mediaDeletePlan,
                    plan.hasDeletableContent
                {
                    HStack(spacing: 8) {
                        FormatPill(text: plan.filter.title.uppercased())
                        FormatPill(
                            text: plan.filter
                                .compactExtensionSummary(selectedExtensions: plan.selectedExtensions)
                                .uppercased()
                        )
                        FormatPill(text: "\(plan.candidateCount) FILES")
                    }
                } else if selectedMediaCopyPreviewMode == .plan,
                    let plan = model.mediaCopyPlan,
                    plan.hasCopyableContent
                {
                    HStack(spacing: 8) {
                        FormatPill(text: plan.filter.title.uppercased())
                        if plan.filter.supportsExtensionSelection {
                            FormatPill(
                                text: plan.filter
                                    .compactExtensionSummary(selectedExtensions: plan.selectedExtensions)
                                    .uppercased()
                            )
                        }
                        FormatPill(text: "\(plan.candidateCount) FILES")
                        if plan.directoryCount > 0 {
                            FormatPill(text: "\(plan.directoryCount) FOLDERS")
                        }
                    }
                } else if selectedMediaCopyPreviewMode == .queue,
                    model.mediaCopyQueueTotalCount > 0
                {
                    HStack(spacing: 8) {
                        FormatPill(text: "\(model.mediaCopyQueueTotalCount) WORKFLOWS")
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            mediaCopyResultsContent
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var mediaCopyResultsContent: some View {
        if model.fileManagementMode == .rename {
            mediaRenameResultsContent
        } else if model.fileManagementMode == .delete {
            mediaDeleteResultsContent
        } else if selectedMediaCopyPreviewMode == .queue {
            mediaCopyQueueContent
        } else if model.isMediaCopyScanning {
            CenteredStatusView(
                symbol: "magnifyingglass",
                title: "Scanning folders",
                detail: "Checking \(model.mediaCopyFilter.fileTypeName) files and destination conflicts."
            )
        } else if model.isMediaDeleting {
            CenteredStatusView(
                symbol: "trash",
                title: "Moving files to Trash",
                detail: mediaCopyProgressDetail
            )
        } else if model.isMediaCopying {
            CenteredStatusView(
                symbol: "doc.on.doc",
                title: "Copying files",
                detail: mediaCopyProgressDetail
            )
        } else if model.mediaCopyPlan == nil {
            CenteredStatusView(
                symbol: "folder",
                title: "No copy plan",
                detail: "Select source and destination folders, then scan, copy, or add to queue."
            )
        } else if let plan = model.mediaCopyPlan, !plan.hasCopyableContent {
            CenteredStatusView(
                symbol: plan.filter.symbolName,
                title: "No \(plan.filter.fileTypeName) files found",
                detail: plan.sourceRoot.path(percentEncoded: false)
            )
        } else if let plan = model.mediaCopyPlan {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.mediaCopyPreviewItems) { candidate in
                        MediaCopyCandidateRow(candidate: candidate, filter: plan.filter)
                    }

                    if plan.candidateCount > model.mediaCopyPreviewItems.count {
                        Text(
                            "\(plan.candidateCount - model.mediaCopyPreviewItems.count) more file\(plan.candidateCount - model.mediaCopyPreviewItems.count == 1 ? "" : "s") hidden from preview."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var mediaRenameResultsContent: some View {
        if model.isMediaCopyScanning {
            CenteredStatusView(
                symbol: "magnifyingglass",
                title: "Scanning folders",
                detail: "Preparing rename preview."
            )
        } else if model.isMediaRenaming {
            CenteredStatusView(
                symbol: "pencil",
                title: "Renaming files",
                detail: mediaCopyProgressDetail
            )
        } else if model.mediaRenamePlan == nil {
            CenteredStatusView(
                symbol: "pencil",
                title: "No rename preview",
                detail: "Select source folders and a filter, then refresh the preview."
            )
        } else if let plan = model.mediaRenamePlan, !plan.hasRenameContent {
            CenteredStatusView(
                symbol: plan.filter.symbolName,
                title: "No \(plan.filter.fileTypeName) files found",
                detail: plan.filter.readableExtensionList(selectedExtensions: plan.selectedExtensions)
            )
        } else if let plan = model.mediaRenamePlan {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.mediaRenamePreviewItems) { item in
                        MediaRenameItemRow(item: item)
                    }

                    if plan.itemCount > model.mediaRenamePreviewItems.count {
                        Text(
                            "\(plan.itemCount - model.mediaRenamePreviewItems.count) more file\(plan.itemCount - model.mediaRenamePreviewItems.count == 1 ? "" : "s") hidden from preview."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var mediaDeleteResultsContent: some View {
        if model.isMediaCopyScanning {
            CenteredStatusView(
                symbol: "magnifyingglass",
                title: "Scanning folders",
                detail: "Checking \(model.mediaCopyDeleteSummary)."
            )
        } else if model.isMediaDeleting {
            CenteredStatusView(
                symbol: "trash",
                title: "Moving files to Trash",
                detail: mediaCopyProgressDetail
            )
        } else if model.mediaDeletePlan == nil {
            CenteredStatusView(
                symbol: "folder",
                title: "No delete preview",
                detail: "Select source folders, then choose audio or video extensions."
            )
        } else if let plan = model.mediaDeletePlan, !plan.hasDeletableContent {
            CenteredStatusView(
                symbol: plan.filter.symbolName,
                title: "No \(plan.filter.fileTypeName) files found",
                detail: plan.filter.readableExtensionList(selectedExtensions: plan.selectedExtensions)
            )
        } else if let plan = model.mediaDeletePlan {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.mediaDeletePreviewItems) { candidate in
                        MediaDeleteCandidateRow(candidate: candidate, filter: plan.filter)
                    }

                    if plan.candidateCount > model.mediaDeletePreviewItems.count {
                        Text(
                            "\(plan.candidateCount - model.mediaDeletePreviewItems.count) more file\(plan.candidateCount - model.mediaDeletePreviewItems.count == 1 ? "" : "s") hidden from preview."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var mediaCopyQueueContent: some View {
        if model.mediaCopyQueue.isEmpty {
            CenteredStatusView(
                symbol: "list.bullet.rectangle",
                title: "No queued workflows",
                detail: "Choose a source, destination, and copy mode, then add it to the queue."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.mediaCopyQueue.enumerated()), id: \.element.id) {
                        index,
                        workflow in
                        MediaCopyWorkflowRow(
                            index: index + 1,
                            workflow: workflow,
                            isRunning: model.currentMediaCopyWorkflowID == workflow.id,
                            canModify: !model.isMediaCopyBusy
                        ) {
                            model.removeMediaCopyWorkflowFromQueue(workflow)
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var mediaPlanSummaryLines: some View {
        StatLine(
            title: "Matched",
            value: "\(model.activeMediaMatchedCount)",
            symbol: model.activeMediaPreviewSymbolName,
            color: .teal
        )
        if model.fileManagementMode == .copy {
            StatLine(
                title: "Existing",
                value: "\(model.mediaCopyConflictCount)",
                symbol: "exclamationmark.triangle",
                color: model.mediaCopyConflictCount > 0 ? .orange : .secondary
            )
        }
        if model.fileManagementMode == .rename {
            StatLine(
                title: "Ready",
                value: "\(model.mediaRenameReadyCount)",
                symbol: "checkmark.circle",
                color: .teal
            )
            StatLine(
                title: "Blocked",
                value: "\(model.mediaRenameBlockedCount)",
                symbol: "exclamationmark.triangle",
                color: model.mediaRenameBlockedCount > 0 ? .orange : .secondary
            )
            StatLine(
                title: "Unchanged",
                value: "\(model.mediaRenameUnchangedCount)",
                symbol: "equal",
                color: .secondary
            )
        }
        StatLine(
            title: "Total size",
            value: model.activeMediaTotalSize.formattedFileSize,
            symbol: "externaldrive",
            color: .indigo
        )

        if model.fileManagementMode == .copy,
            let plan = model.mediaCopyPlan,
            plan.directoryCount > 0
        {
            StatLine(
                title: "Folders",
                value: "\(plan.directoryCount)",
                symbol: "folder",
                color: .teal
            )
        }

        if model.fileManagementMode == .copy,
            let plan = model.mediaCopyPlan,
            plan.conflictCount > 0
        {
            Text(
                "\(plan.copyableWithoutOverwriteCount) file\(plan.copyableWithoutOverwriteCount == 1 ? "" : "s") can be copied without replacing existing destination files."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mediaProgressPanel(_ progress: MediaCopyProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fractionCompleted)
            HStack {
                Text("\(progress.completed) of \(progress.total)")
                    .monospacedDigit()
                Spacer()
                Text("\(progress.copied) \(mediaProgressVerb)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Text("\(progress.copiedBytes.formattedFileSize) \(mediaProgressVerb)")
                    .monospacedDigit()
                Spacer()
                Text(mediaCopySpeedText(for: progress))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let currentName = progress.currentName {
                Text(currentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var mediaManagementActions: some View {
        if model.isMediaCopyBusy {
            Button {
                model.cancelMediaCopy()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        } else {
            VStack(spacing: 10) {
                switch model.fileManagementMode {
                case .copy:
                    Button {
                        model.scanMediaCopyFiles()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canPrepareMediaCopy)

                    Button {
                        model.copyFilteredMediaFiles()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Copy now", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPrepareMediaCopy)

                    Button {
                        model.addCurrentMediaCopyWorkflowToQueue()
                        selectedMediaCopyPreviewMode = .queue
                    } label: {
                        Label("Add to queue", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canAddMediaCopyWorkflowToQueue)
                case .delete:
                    Button {
                        model.refreshMediaDeletePreview()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Refresh preview", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canRefreshMediaDeletePreview)

                    Button(role: .destructive) {
                        model.deleteFilteredMediaFiles()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Delete filtered files", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(!model.canDeleteFilteredMediaFiles)
                    .help("Move files from source folders to the macOS Trash using the selected filter")
                case .rename:
                    Button {
                        model.refreshMediaRenamePreview()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Refresh preview", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canRefreshMediaRenamePreview)

                    Button {
                        model.renameFilteredMediaFiles()
                        selectedMediaCopyPreviewMode = .plan
                    } label: {
                        Label("Rename files", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canRenameFilteredMediaFiles)

                    HStack(spacing: 8) {
                        Button {
                            model.undoLastMediaRename()
                            selectedMediaCopyPreviewMode = .plan
                        } label: {
                            Label(model.mediaRenameUndoButtonTitle, systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.canUndoMediaRename)
                        .help(model.mediaRenameUndoHelp)

                        Button {
                            model.redoLastMediaRename()
                            selectedMediaCopyPreviewMode = .plan
                        } label: {
                            Label(model.mediaRenameRedoButtonTitle, systemImage: "arrow.uturn.forward")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.canRedoMediaRename)
                        .help(model.mediaRenameRedoHelp)
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button {
                        model.restoreTrashedSources()
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canRestoreTrashedSources)
                    .help("Restore files moved to Trash by GPhilCoder")

                    Button(role: .destructive) {
                        model.clearTrashedSourceRecords()
                    } label: {
                        Label("Clear records", systemImage: "trash.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canClearTrashedSourceRecords)
                    .help("Forget saved restore records without changing any files")
                }
                .controlSize(.small)
            }
        }
    }

    private var mediaCopyQueueGroup: some View {
        GroupBox("Queue") {
            VStack(alignment: .leading, spacing: 10) {
                StatLine(
                    title: "Workflows",
                    value: "\(model.mediaCopyQueueTotalCount)",
                    symbol: "list.bullet.rectangle",
                    color: .indigo
                )

                HStack(spacing: 8) {
                    Button {
                        model.loadMediaCopyJob()
                        selectedMediaCopyPreviewMode = .queue
                    } label: {
                        Label("Load", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        model.saveMediaCopyJob()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canSaveMediaCopyJob)
                }
                .controlSize(.small)

                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        model.clearMediaCopyQueue()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.mediaCopyQueueTotalCount == 0 || model.isMediaCopyBusy)

                    Button {
                        model.runMediaCopyQueue()
                        selectedMediaCopyPreviewMode = .queue
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunMediaCopyQueue)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var mediaCopySubtitle: String {
        if model.fileManagementMode == .rename {
            if model.isMediaCopyScanning {
                return "Scanning filtered files for rename preview."
            }

            if model.isMediaRenaming {
                return mediaCopyProgressDetail
            }

            guard let plan = model.mediaRenamePlan else {
                return "No source-folder scan has been run."
            }

            if model.isMediaRenamePreviewStale {
                return "Preview is stale. Refresh before renaming."
            }

            if !plan.hasRenameContent {
                return "No matching \(plan.filter.fileTypeName) files found."
            }

            if plan.blockedCount > 0 {
                return "\(plan.readyCount) ready, \(plan.blockedCount) blocked."
            }

            if plan.unchangedCount > 0 {
                return "\(plan.readyCount) ready, \(plan.unchangedCount) unchanged."
            }

            return "\(plan.readyCount) ready to rename."
        }

        if model.fileManagementMode == .delete {
            if model.isMediaCopyScanning {
                return "Scanning filtered files for deletion."
            }

            if model.isMediaDeleting {
                return mediaCopyProgressDetail
            }

            guard let plan = model.mediaDeletePlan else {
                return "No source-folder scan has been run."
            }

            if !plan.hasDeletableContent {
                return "No matching \(plan.filter.fileTypeName) files found."
            }

            return "\(plan.candidateCount) matched for Trash."
        }

        if selectedMediaCopyPreviewMode == .queue {
            if model.isMediaCopyScanning {
                return "Scanning queued file copy workflows."
            }

            if model.isMediaCopying {
                return mediaCopyProgressDetail
            }

            let count = model.mediaCopyQueueTotalCount
            return count == 0
                ? "No queued file copy workflows."
                : "\(count) queued file copy workflow\(count == 1 ? "" : "s")."
        }

        if model.isMediaCopyScanning {
            return "Scanning \(model.mediaCopyFilter.fileTypeName) files."
        }

        if model.isMediaDeleting {
            return mediaCopyProgressDetail
        }

        if model.isMediaCopying {
            return mediaCopyProgressDetail
        }

        guard let plan = model.mediaCopyPlan else {
            return "No source and destination scan has been run."
        }

        if !plan.hasCopyableContent {
            return "No matching \(plan.filter.fileTypeName) files found."
        }

        if plan.conflictCount > 0 {
            return
                "\(plan.candidateCount) matched, \(plan.conflictCount) already exist in the destination."
        }

        return "\(plan.candidateCount) matched, no destination conflicts."
    }



    private var mediaCopyProgressDetail: String {
        guard let progress = model.mediaCopyProgress else {
            if model.isMediaDeleting {
                return "Preparing filtered delete."
            }
            if model.isMediaRenaming {
                return "Preparing rename."
            }
            return "Preparing copy."
        }

        let speedDetail = progress.bytesPerSecond
            .map { ", \($0.formattedMegabytesPerSecond)" } ?? ""
        if model.isMediaDeleting {
            return
                "\(progress.completed) of \(progress.total) processed, \(progress.copied) moved, \(progress.failed) failed\(speedDetail)."
        }
        if model.isMediaRenaming {
            return
                "\(progress.completed) of \(progress.total) processed, \(progress.copied) \(model.mediaRenameProgressVerb), \(progress.failed) failed\(speedDetail)."
        }
        return
            "\(progress.completed) of \(progress.total) processed, \(progress.copied) copied, \(progress.skippedExisting) skipped, \(progress.failed) failed\(speedDetail)."
    }

    private var mediaProgressVerb: String {
        if model.isMediaDeleting {
            return "moved"
        }
        if model.isMediaRenaming {
            return model.mediaRenameProgressVerb
        }
        return "copied"
    }

    private func mediaCopySpeedText(for progress: MediaCopyProgress) -> String {
        progress.bytesPerSecond?.formattedMegabytesPerSecond ?? "Calculating speed"
    }
}
