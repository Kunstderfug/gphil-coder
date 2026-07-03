import AppKit
import GPhilCoderCore
import SwiftUI
import UniformTypeIdentifiers

private enum WorkflowTab: CaseIterable, Hashable, Identifiable {
    case audioEncoding
    case videoEncoding
    case mediaCopy
    case mediaRename
    case mediaDelete
    case folderSync
    case backupRestore

    var id: Self { self }

    var title: String {
        switch self {
        case .audioEncoding:
            "Audio"
        case .videoEncoding:
            "Video"
        case .mediaCopy:
            "Copy"
        case .mediaRename:
            "Rename"
        case .mediaDelete:
            "Delete"
        case .folderSync:
            "Sync"
        case .backupRestore:
            "Restore"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .audioEncoding:
            "Audio Encoding"
        case .videoEncoding:
            "Video Encoding"
        case .mediaCopy:
            "Copy"
        case .mediaRename:
            "Rename"
        case .mediaDelete:
            "Delete"
        case .folderSync:
            "Sync"
        case .backupRestore:
            "Restore"
        }
    }

    var symbolName: String {
        switch self {
        case .audioEncoding:
            "waveform"
        case .videoEncoding:
            "film"
        case .mediaCopy:
            "doc.on.doc"
        case .mediaRename:
            "pencil"
        case .mediaDelete:
            "trash"
        case .folderSync:
            "arrow.triangle.2.circlepath"
        case .backupRestore:
            "externaldrive.badge.icloud"
        }
    }
}

private enum MediaCopyPreviewMode: Hashable {
    case plan
    case queue
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: EncoderViewModel
    @State private var selectedWorkflowTab: WorkflowTab = .audioEncoding
    @State private var selectedMediaCopyPreviewMode: MediaCopyPreviewMode = .plan
    @State private var showingInputFilterSheet = false
    @State private var isEncodingDropTargeted = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titlebarSpacer
                topBar
                Divider()
                workflowContentContainer
                Divider()
                footer
            }
        }
        .accentColor(.teal)
        .sheet(isPresented: $showingInputFilterSheet) {
            InputFilterSheet()
                .environmentObject(model)
        }
        .onAppear {
            syncWorkflowSelection(selectedWorkflowTab)
        }
        .onChange(of: selectedWorkflowTab) { _, tab in
            syncWorkflowSelection(tab)
        }
    }

    private var workflowTabBar: some View {
        HStack(spacing: 6) {
            ForEach(WorkflowTab.allCases) { tab in
                WorkflowTabButton(
                    tab: tab,
                    isSelected: selectedWorkflowTab == tab
                ) {
                    selectedWorkflowTab = tab
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var selectedWorkflowContent: some View {
        switch selectedWorkflowTab {
        case .audioEncoding:
            audioEncodingWorkflow
        case .videoEncoding:
            audioEncodingWorkflow
        case .mediaCopy:
            fileManagementWorkflow(for: .copy)
        case .mediaRename:
            fileManagementWorkflow(for: .rename)
        case .mediaDelete:
            fileManagementWorkflow(for: .delete)
        case .folderSync:
            folderSyncWorkflow
        case .backupRestore:
            backupRestoreWorkflow
        }
    }

    private var workflowContentContainer: some View {
        GeometryReader { proxy in
            selectedWorkflowContent
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var titlebarSpacer: some View {
        Color.clear
            .frame(height: 10)
            .background(.bar)
    }

    private func syncWorkflowSelection(_ tab: WorkflowTab) {
        switch tab {
        case .audioEncoding:
            model.encodingWorkflow = .audio
        case .videoEncoding:
            model.encodingWorkflow = .video
        case .backupRestore:
            break
        case .folderSync:
            break
        case .mediaCopy:
            model.fileManagementMode = .copy
            selectedMediaCopyPreviewMode = .plan
        case .mediaRename:
            model.fileManagementMode = .rename
        case .mediaDelete:
            model.fileManagementMode = .delete
        }
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                HeaderAppIcon()

                VStack(alignment: .leading, spacing: 2) {
                    Text("GPhil Coder")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(
                        "Batch audio/video encoding and filtered media workflows"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                ToolStatusView()
            }

            workflowTabBar
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private var audioEncodingWorkflow: some View {
        HStack(spacing: 0) {
            libraryPanel
                .frame(width: 268)

            Divider()

            queuePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            settingsPanel
                .frame(width: 320)
        }
    }

    private func fileManagementWorkflow(for mode: FileManagementMode) -> some View {
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

    private var backupRestoreWorkflow: some View {
        RestoreFromBackupSheet(isEmbedded: true)
            .environmentObject(model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderSyncWorkflow: some View {
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
                    Toggle("Sync deletions", isOn: model.binding(\.syncDeleteDestinationItems))
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
                        title: "Changes",
                        value: "\(model.syncPendingOperationCount)",
                        symbol: "arrow.left.arrow.right",
                        color: .indigo
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
        if model.isFolderSyncBusy {
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
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canRunFolderSync)
            }
        }
    }

    private var folderSyncResultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder Sync")
                        .font(.title3.weight(.semibold))
                    Text(folderSyncSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.syncAutoSyncEnabled {
                    FormatPill(text: "AUTO")
                }
                if model.syncPendingOperationCount > 0 {
                    FormatPill(text: "\(model.syncPendingOperationCount) CHANGES")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            folderSyncResultsContent
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var folderSyncResultsContent: some View {
        if model.isSyncScanning {
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

                    if !model.syncPreviewItems.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        ForEach(model.syncPreviewItems) { operation in
                            FolderSyncOperationRow(operation: operation)
                        }

                        if model.syncPendingOperationCount > model.syncPreviewItems.count {
                            Text(
                                "\(model.syncPendingOperationCount - model.syncPreviewItems.count) more change\(model.syncPendingOperationCount - model.syncPreviewItems.count == 1 ? "" : "s") hidden from preview."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                        }
                    }
                }
                .padding(18)
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

    private var folderSyncSubtitle: String {
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
        if model.syncPendingOperationCount > 0 {
            return
                "\(model.syncPendingOperationCount) pending change\(model.syncPendingOperationCount == 1 ? "" : "s") across \(model.syncEnabledPairCount) enabled pair\(model.syncEnabledPairCount == 1 ? "" : "s")."
        }
        return model.syncWatcherStatusTitle
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

    private var libraryPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Input")
                            .font(.headline)

                        HStack(spacing: 10) {
                            Button {
                                model.addFiles()
                            } label: {
                                Label("Files", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isEncoding)

                            Button {
                                model.addFolder()
                            } label: {
                                Label("Folder", systemImage: "folder.badge.plus")
                            }
                            .disabled(model.isEncoding)
                        }

                        HStack(spacing: 8) {
                            Button {
                                model.saveQueue()
                            } label: {
                                Label("Save queue", systemImage: "square.and.arrow.down")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!model.canSaveQueue)

                            Button {
                                model.loadQueue()
                            } label: {
                                Label("Load queue", systemImage: "square.and.arrow.up")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(model.isEncoding)
                        }
                        .controlSize(.small)
                    }

                    inputFilterControls

                    VStack(alignment: .leading, spacing: 10) {
                        StatLine(
                            title: "Active", value: "\(model.activeInputs.count)",
                            symbol: model.encodingWorkflow.symbolName,
                            color: .teal)
                        StatLine(
                            title: "Active size", value: model.activeInputSize.formattedFileSize,
                            symbol: "externaldrive", color: .indigo)
                        StatLine(
                            title: "Filter", value: model.selectedInputReadableList,
                            symbol: "line.3.horizontal.decrease.circle", color: .orange)
                    }
                    .padding(12)
                    .background(
                        .quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Current route", systemImage: "arrow.triangle.branch")
                            .font(.subheadline.weight(.semibold))
                        Text(outputRouteDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    model.clearInputs()
                } label: {
                    Label("Clear queue", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.inputs.isEmpty || model.isEncoding)

                Button(role: .destructive) {
                    model.trashAllInputSources()
                } label: {
                    Label(
                        model.jobStateFilterTitle == nil
                            ? "Move active sources to Trash" : "Move filtered sources to Trash",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.canTrashQueueSources)
                .help(
                    "Move only source files matching the current queue filters to the macOS Trash")

                Button {
                    model.restoreTrashedSources()
                } label: {
                    Label(
                        "Restore trashed sources\(model.trashedSourceRecords.isEmpty ? "" : " (\(model.trashedSourceRecords.count))")",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.canRestoreTrashedSources)
                .help("Restore source files moved to Trash by GPhilCoder")

                Button(role: .destructive) {
                    model.clearTrashedSourceRecords()
                } label: {
                    Label(
                        "Clear restore records\(model.trashedSourceRecords.isEmpty ? "" : " (\(model.trashedSourceRecords.count))")",
                        systemImage: "trash.slash"
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.canClearTrashedSourceRecords)
                .help("Forget saved restore records without changing any files")
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inputFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input filters", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline.weight(.semibold))

            Button {
                showingInputFilterSheet = true
            } label: {
                HStack(spacing: 8) {
                    Text(model.selectedInputReadableList)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(model.isEncoding)
            .help("Choose input \(model.encodingWorkflow.title.lowercased()) formats")
        }
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.jobs.isEmpty ? "Input Queue" : "Encoding Jobs")
                        .font(.title3.weight(.semibold))
                    Text(queueSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !model.jobs.isEmpty {
                    JobSummaryStrip(
                        completed: model.completedCount,
                        running: model.runningCount,
                        queued: model.queuedCount,
                        skipped: model.skippedCount,
                        failed: model.failedCount,
                        selectedState: model.jobStateFilter
                    ) { state in
                        model.toggleJobStateFilter(state)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            if model.jobs.isEmpty {
                inputList
            } else {
                jobList
            }
        }
        .overlay {
            if isEncodingDropTargeted && !model.isEncoding {
                DropTargetOverlay(workflow: model.encodingWorkflow)
                    .padding(22)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isEncodingDropTargeted
        ) { providers in
            model.addDroppedItems(providers)
            return true
        }
    }

    private var inputList: some View {
        Group {
            if model.inputs.isEmpty {
                EmptyQueueView(workflow: model.encodingWorkflow)
            } else if model.activeInputs.isEmpty {
                EmptyFilteredQueueView(hiddenCount: model.inactiveInputCount)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.activeInputs) { item in
                            InputRow(item: item, canModify: !model.isEncoding) {
                                model.removeInput(item)
                            } trashSource: {
                                model.trashInputSource(item)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var jobList: some View {
        Group {
            if model.visibleJobs.isEmpty {
                EmptyJobFilterView(filterTitle: model.jobStateFilterTitle ?? "selected")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.visibleJobs) { job in
                            JobRow(job: job) {
                                model.revealOutput(for: job)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    presetControls

                    GroupBox("Output") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("", selection: model.binding(\.outputMode)) {
                                ForEach(OutputMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .disabled(model.isEncoding)

                            if model.outputMode == .exportFolder {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.teal)
                                        Text(
                                            model.exportFolder?.path(percentEncoded: false)
                                                ?? "No export folder selected"
                                        )
                                        .lineLimit(2)
                                        .font(.callout)
                                        .foregroundStyle(model.exportFolder == nil ? .secondary : .primary)
                                    }

                                    Button {
                                        model.chooseExportFolder()
                                    } label: {
                                        Label("Choose folder", systemImage: "folder.badge.gearshape")
                                    }
                                    .disabled(model.isEncoding)

                                    Toggle("Preserve subfolders", isOn: model.binding(\.preserveSubfolders))
                                        .disabled(model.isEncoding)
                                }
                            } else {
                                Text(
                                    "\(model.outputFormatTitle) files are written next to each source file. Files added from nested folders stay in those folders."
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Encoding") {
                        VStack(alignment: .leading, spacing: 13) {
                            outputFormatPicker

                            Text(model.outputFormatDetail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            formatEncodingControls

                            Stepper(value: model.binding(\.parallelJobs), in: 1...model.processorLimit) {
                                SettingValue(title: "Parallel jobs", value: "\(model.parallelJobs)")
                            }
                            .disabled(model.isEncoding)

                            Stepper(value: model.binding(\.ffmpegThreads), in: 0...model.processorLimit) {
                                SettingValue(
                                    title: "FFmpeg threads",
                                    value: model.ffmpegThreads == 0 ? "Auto" : "\(model.ffmpegThreads)"
                                )
                            }
                            .disabled(model.isEncoding)

                            Toggle(
                                "Overwrite existing \(model.outputFormatTitle) files",
                                isOn: model.binding(\.overwriteExisting)
                            )
                            .disabled(model.isEncoding)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Start") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(
                                "Confirm before starting \(model.encodingWorkflow.title.lowercased()) jobs",
                                isOn: model.binding(\.confirmBeforeEncoding)
                            )
                            .disabled(model.isEncoding)

                            Text(model.startConfirmationContext)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Format") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                FormatPill(text: model.encodingWorkflow.title.uppercased())
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                FormatPill(text: model.outputFormatTitle)
                            }
                            Text(
                                "The queue keeps every supported \(model.encodingWorkflow.title.lowercased()) file you add. Input filters choose which queued formats are visible and sent to FFmpeg's \(model.selectedEncoderName) encoder."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if let warning = model.sameFormatWarningMessage {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let warning = model.lossyToLosslessWarningMessage {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let warning = model.nativeOggReencodeWarningMessage {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let warning = model.videoEncodingWarningMessage {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(18)
            }

            Divider()

            Group {
                if model.isEncoding {
                    Button {
                        model.cancelEncoding()
                    } label: {
                        Label("Cancel encoding", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                } else {
                    Button {
                        model.startEncoding()
                    } label: {
                        Label("Start encoding", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canEncode)
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var presetControls: some View {
        GroupBox("Presets") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "Preset",
                    selection: Binding<UUID?>(
                        get: { model.selectedEncodingPresetID },
                        set: { model.setSelectedEncodingPresetID($0) }
                    )
                ) {
                    Text("No preset").tag(Optional<UUID>.none)
                    ForEach(model.workflowEncodingPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .disabled(model.isEncoding)

                Text(model.selectedEncodingPresetSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isLoadedPresetDirty {
                    Text("● modified")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .help("Working settings differ from the selected preset. Use Update to save them back, or Load to reset.")
                }
                HStack(spacing: 8) {
                    Button {
                        model.loadSelectedEncodingPreset()
                    } label: {
                        Label("Load", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canLoadSelectedEncodingPreset)

                    Menu {
                        Button {
                            model.updateSelectedEncodingPreset()
                        } label: {
                            Label("Update Current Preset", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!model.canUpdateSelectedEncodingPreset)

                        Button {
                            model.saveCurrentSettingsAsEncodingPreset()
                        } label: {
                            Label("Save As New Preset", systemImage: "plus.circle")
                        }
                        .disabled(model.isEncoding)

                        Button {
                            model.renameSelectedEncodingPreset()
                        } label: {
                            Label("Rename Preset", systemImage: "pencil")
                        }
                        .disabled(!model.canUpdateSelectedEncodingPreset)

                        Divider()

                        Button(role: .destructive) {
                            model.deleteSelectedEncodingPreset()
                        } label: {
                            Label("Delete Preset", systemImage: "trash")
                        }
                        .disabled(!model.canDeleteSelectedEncodingPreset)

                        Divider()

                        Button {
                            openWindow(id: AppWindowID.encodingPresets)
                        } label: {
                            Label("Manage Presets", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 28)
                    }
                    .disabled(model.isEncoding)
                    .help("Preset actions")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var outputFormatPicker: some View {
        switch model.encodingWorkflow {
        case .audio:
            Picker("Output format", selection: model.binding(\.outputFormat)) {
                ForEach(AudioOutputFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isEncoding)
        case .video:
            Picker("Container", selection: model.binding(\.videoOutputContainer)) {
                ForEach(VideoOutputContainer.allCases) { container in
                    Text(container.title).tag(container)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)
            .arrowCursorOnHover()
        }
    }

    @ViewBuilder
    private var formatEncodingControls: some View {
        if model.encodingWorkflow == .video {
            videoEncodingControls
        } else {
        switch model.outputFormat {
        case .mp3:
            Picker("MP3 mode", selection: model.binding(\.mp3Mode)) {
                ForEach(MP3EncodingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)
            .arrowCursorOnHover()

            Text(model.mp3Mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            mp3ModeControls

        case .ogg:
            Picker("Ogg mode", selection: model.binding(\.oggMode)) {
                ForEach(OggEncodingOptions.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)
            .arrowCursorOnHover()

            Text(model.oggMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.oggMode {
            case .bitrate:
                Picker("Bitrate", selection: model.binding(\.oggBitrateKbps)) {
                    ForEach(OggEncodingOptions.bitrateKbps, id: \.self) { bitrate in
                        Text("\(bitrate) kbps").tag(bitrate)
                    }
                }
                .disabled(model.isEncoding)

                if !model.supportsOggBitrate {
                    Text(
                        "This FFmpeg build does not include libvorbis, so Ogg bitrate mode is unavailable. Use Quality mode or install an FFmpeg build with libvorbis."
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

            case .quality:
                Picker("Quality", selection: model.binding(\.oggQuality)) {
                    ForEach(OggEncodingOptions.qualities, id: \.self) { quality in
                        Text(OggEncodingOptions.qualityLabel(quality)).tag(quality)
                    }
                }
                .disabled(model.isEncoding)

                Text(
                    "Quality mode does not set a fixed bitrate. Player bitrate readouts show the total stream average, so stereo files are not shown as per-channel values."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

        case .opus:
            Picker("Opus mode", selection: model.binding(\.opusRateMode)) {
                ForEach(OpusEncodingOptions.RateMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)
            .arrowCursorOnHover()

            Picker("Bitrate", selection: model.binding(\.opusBitrateKbps)) {
                ForEach(OpusEncodingOptions.bitrateKbps, id: \.self) { bitrate in
                    Text("\(bitrate) kbps").tag(bitrate)
                }
            }
            .disabled(model.isEncoding)

            Text(model.opusRateMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "512 kbps is valid for stereo Opus. Mono Opus sources may be limited to 256 kbps by libopus."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        case .flac:
            Picker("Compression", selection: model.binding(\.flacCompressionLevel)) {
                ForEach(FLACEncodingOptions.compressionLevels, id: \.self) { level in
                    Text(FLACEncodingOptions.compressionLevelLabel(level)).tag(level)
                }
            }
            .disabled(model.isEncoding)

            Text(
                "FLAC is lossless. Higher compression levels can make smaller files, but encoding is slower. FLAC supports up to 8 channels; use WavPack for larger immersive layouts."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            multichannelSplitToggle

        case .wavpack:
            Text(
                "WavPack output is lossless and preserves high-bit-depth sources. For DAW/player compatibility, keep immersive layouts within the 18 standard named speaker channels; larger layouts should stay as WAV/RF64/W64 or split stems."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            multichannelSplitToggle
        }
        }
    }

    private var videoEncodingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("HEVC preset", selection: model.binding(\.hevcPreset)) {
                ForEach(HEVCVideoPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isEncoding)

            Text(model.hevcPreset.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.hevcPreset == .custom {
                Stepper(value: model.binding(\.customVideoBitrateKbps), in: 500...100_000, step: 500) {
                    SettingValue(
                        title: "Video bitrate",
                        value: "\(model.customVideoBitrateKbps) kbps"
                    )
                }
                .disabled(model.isEncoding)
            } else {
                SettingValue(title: "Video bitrate", value: "\(model.videoBitrateKbps) kbps")
            }

            Picker("Resolution", selection: model.binding(\.videoScaleMode)) {
                ForEach(VideoScaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)

            Text(model.videoScaleMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Audio", selection: model.binding(\.videoAudioMode)) {
                ForEach(VideoAudioMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isEncoding)

            Text(model.videoAudioMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Decode", selection: model.binding(\.videoHardwareDecodeMode)) {
                ForEach(VideoHardwareDecodeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)

            Text(model.videoHardwareDecodeMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Video uses Apple's HEVC VideoToolbox encoder and blocks software fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var multichannelSplitToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Split oversized multichannel sources",
                isOn: model.binding(\.splitOversizedMultichannel)
            )
            .disabled(model.isEncoding)

            Text(
                "When a source exceeds the selected codec's compatible channel count, write channel-order chunks instead of one unsupported file. WavPack uses chunks like _ch1-10 and _ch11-21; FLAC uses up to 8 channels per chunk."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var mp3ModeControls: some View {
        switch model.mp3Mode {
        case .vbr:
            Picker("Quality", selection: model.binding(\.vbrQuality)) {
                ForEach(MP3EncodingOptions.vbrQualities, id: \.self) { quality in
                    Text(MP3EncodingOptions.vbrQualityLabel(quality)).tag(quality)
                }
            }
            .disabled(model.isEncoding)

        case .cbr:
            Picker("Bitrate", selection: model.binding(\.cbrBitrateKbps)) {
                ForEach(MP3EncodingOptions.bitrateKbps, id: \.self) { bitrate in
                    Text("\(bitrate) kbps").tag(bitrate)
                }
            }
            .disabled(model.isEncoding)

        case .abr:
            Picker("Target", selection: model.binding(\.abrBitrateKbps)) {
                ForEach(MP3EncodingOptions.bitrateKbps, id: \.self) { bitrate in
                    Text("\(bitrate) kbps").tag(bitrate)
                }
            }
            .disabled(model.isEncoding)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(
                systemName: model.encodingFFmpegURL == nil ? "exclamationmark.triangle.fill" : "info.circle"
            )
            .foregroundStyle(model.encodingFFmpegURL == nil ? .orange : .secondary)
            Text(model.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

            if model.encodingWorkflow == .video {
                VideoPipelineStatusBadges()
                    .environmentObject(model)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var outputRouteDescription: String {
        switch model.outputMode {
        case .sourceFolders:
            return "Write \(model.outputFormatTitle) files beside each source file."
        case .exportFolder:
            if let exportFolder = model.exportFolder {
                let suffix = model.preserveSubfolders ? " and preserve nested folders." : "."
                return
                    "Write \(model.outputFormatTitle) files to \(exportFolder.lastPathComponent)\(suffix)"
            }
            return "Choose a destination folder before encoding."
        }
    }

    private var queueSubtitle: String {
        if model.jobs.isEmpty {
            return model.inputs.isEmpty
                ? "Drop into the workflow by adding files or folders."
                : "\(model.activeInputs.count) of \(model.inputs.count) queued \(model.encodingWorkflow.queueNoun)\(model.inputs.count == 1 ? "" : "s") active."
        }

        if model.isEncoding {
            return "\(model.runningCount) running, \(model.queuedCount) waiting."
        }

        if let filterTitle = model.jobStateFilterTitle {
            return
                "\(model.visibleJobCount) \(filterTitle.lowercased()) job\(model.visibleJobCount == 1 ? "" : "s") shown. Queue actions use this filtered set."
        }

        return
            "\(model.completedCount) done, \(model.skippedCount) skipped, \(model.failedCount) failed."
    }
}

private struct VideoPipelineStatusBadges: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(
                text: model.videoDecodeModeTitle,
                systemImage: model.videoHardwareDecodeMode.usesVideoToolbox
                    ? "bolt.horizontal.fill"
                    : "cpu",
                color: model.videoHardwareDecodeMode.usesVideoToolbox ? .green : .secondary,
                helpText: model.videoDecodeModeDetail
            )

            StatusBadge(
                text: model.videoScaleModeTitle,
                systemImage: model.videoScaleMode.usesSoftwareScale
                    ? "arrow.down.right.and.arrow.up.left"
                    : "rectangle",
                color: model.videoScaleMode.usesSoftwareScale ? .orange : .secondary,
                helpText: model.videoScaleModeDetail
            )

            StatusBadge(
                text: model.videoEncodeModeTitle,
                systemImage: model.supportsHEVCVideoToolbox
                    ? "bolt.horizontal.circle.fill"
                    : "exclamationmark.triangle.fill",
                color: model.supportsHEVCVideoToolbox ? .green : .orange,
                helpText: model.videoEncodeModeDetail
            )
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color
    let helpText: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .help(helpText)
    }
}

private struct ToolStatusView: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.encodingFFmpegURL == nil ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .foregroundStyle(model.encodingFFmpegURL == nil ? .orange : .green)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    model.encodingFFmpegURL == nil
                        ? "\(model.ffmpegSourceTitle) FFmpeg missing"
                        : "\(model.ffmpegSourceTitle) FFmpeg ready"
                )
                .font(.subheadline.weight(.semibold))
                Text(model.activeFFmpegPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)

                Text(videoStatusLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .leading)
                    .opacity(model.encodingWorkflow == .video ? 1 : 0)
                    .help(videoStatusHelp)
                    .accessibilityHidden(model.encodingWorkflow != .video)
            }

            Picker("FFmpeg", selection: model.binding(\.ffmpegSourcePreference)) {
                ForEach(FFmpegSourcePreference.selectableCases) { source in
                    Text(sourceLabel(source))
                        .tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)
            .disabled(model.isEncoding || model.encodingWorkflow == .video)
            .help(
                model.encodingWorkflow == .video
                    ? "Video encoding uses system FFmpeg for HEVC VideoToolbox."
                    : "Choose whether audio encoding uses the app-bundled FFmpeg or the FFmpeg installed on this Mac."
            )

            Button {
                model.refreshFFmpeg()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.gphilHoverBorderless)
            .help("Refresh FFmpeg detection")

            Divider()
                .frame(height: 28)

            NotificationStatusControl()
                .environmentObject(model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceLabel(_ source: FFmpegSourcePreference) -> String {
        if model.isFFmpegSourceAvailable(source) {
            return source.title
        }
        return "\(source.title) missing"
    }

    private var videoStatusLine: String {
        guard model.encodingWorkflow == .video else { return "Reserved video pipeline status" }
        return "\(model.videoDecodeModeTitle) | \(model.videoScaleModeTitle) | \(model.videoEncodeModeTitle)"
    }

    private var videoStatusHelp: String {
        guard model.encodingWorkflow == .video else { return "" }
        return "\(model.videoDecodeModeDetail). \(model.videoScaleModeDetail). \(model.videoEncodeModeDetail)."
    }
}

private struct NotificationStatusControl: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: model.notificationPermission.symbolName)
                .foregroundStyle(statusColor)

            Text(notificationTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if model.notificationPermission == .enabled {
                Toggle("Alerts", isOn: model.binding(\.completionNotificationsEnabled))
                    .labelsHidden()
                    .controlSize(.small)
                    .toggleStyle(.switch)

                Button {
                    model.sendTestNotification()
                } label: {
                    Text("Test")
                }
                .controlSize(.small)
                .disabled(!model.completionNotificationsEnabled)

                Button {
                    model.clearDeliveredNotifications()
                } label: {
                    Text("Clear")
                }
                .controlSize(.small)
            } else {
                Button {
                    if model.notificationPermission == .denied {
                        model.openNotificationSettings()
                    } else {
                        model.requestNotificationPermission()
                    }
                } label: {
                    Text(actionTitle)
                }
                .controlSize(.small)
            }
        }
        .help(model.notificationPermission.detail)
    }

    private var notificationTitle: String {
        if model.notificationPermission == .enabled, !model.completionNotificationsEnabled {
            return "Alerts muted"
        }

        return switch model.notificationPermission {
        case .enabled:
            "Alerts on"
        case .denied:
            "Alerts denied"
        case .notDetermined:
            "Enable alerts"
        case .unknown:
            "Alerts"
        }
    }

    private var actionTitle: String {
        model.notificationPermission == .denied ? "Settings" : "Enable"
    }

    private var statusColor: Color {
        switch model.notificationPermission {
        case .enabled:
            .green
        case .denied:
            .orange
        case .notDetermined, .unknown:
            .secondary
        }
    }
}

private struct InputFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Input Filters")
                        .font(.title3.weight(.semibold))
                    Text("Choose which \(model.encodingWorkflow.title.lowercased()) extensions are accepted when adding files or folders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.gphilHoverBorderless)
                .help("Close")
            }

            Divider()

            inputToggles

            Text("Current selection: \(model.selectedInputReadableList)")
                .font(.callout)
                .foregroundStyle(model.hasSelectedInputFilters ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    model.selectAllInputFormats()
                } label: {
                    Label("Select all", systemImage: "checklist.checked")
                }
                .disabled(model.isEncoding)

                Button {
                    model.deselectAllInputFormats()
                } label: {
                    Label("Deselect all", systemImage: "checklist.unchecked")
                }
                .disabled(model.isEncoding)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    @ViewBuilder
    private var inputToggles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
            switch model.encodingWorkflow {
            case .audio:
                ForEach(InputAudioFormat.allCases) { format in
                    Toggle(
                        format.title,
                        isOn: Binding(
                            get: { model.isInputFormatEnabled(format) },
                            set: { model.setInputFormat(format, enabled: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .disabled(model.isEncoding)
                }
            case .video:
                ForEach(InputVideoFormat.allCases) { format in
                    Toggle(
                        format.title,
                        isOn: Binding(
                            get: { model.isInputFormatEnabled(format) },
                            set: { model.setInputFormat(format, enabled: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .disabled(model.isEncoding)
                }
            }
        }
    }
}

private struct StatLine: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .font(.callout)
    }
}

private struct JobSummaryStrip: View {
    let completed: Int
    let running: Int
    let queued: Int
    let skipped: Int
    let failed: Int
    let selectedState: JobState?
    let toggle: (JobState) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SummaryChip(
                title: "Success",
                value: completed,
                symbol: "checkmark",
                color: .green,
                isSelected: selectedState == .succeeded
            ) {
                toggle(.succeeded)
            }
            SummaryChip(
                title: "Running",
                value: running,
                symbol: "waveform",
                color: .teal,
                isSelected: selectedState == .running
            ) {
                toggle(.running)
            }
            SummaryChip(
                title: "Queued",
                value: queued,
                symbol: "clock",
                color: .secondary,
                isSelected: selectedState == .queued
            ) {
                toggle(.queued)
            }
            SummaryChip(
                title: "Skipped",
                value: skipped,
                symbol: "forward.end",
                color: .orange,
                isSelected: selectedState == .skipped
            ) {
                toggle(.skipped)
            }
            SummaryChip(
                title: "Failed",
                value: failed,
                symbol: "xmark",
                color: .red,
                isSelected: selectedState == .failed
            ) {
                toggle(.failed)
            }
        }
    }
}

private struct SummaryChip: View {
    let title: String
    let value: Int
    let symbol: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(1)
                Text("\(value)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                summaryChipBackground,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isSelected || isHovering
                            ? color.opacity(isSelected ? 0.7 : 0.35)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(value == 0 && !isSelected)
        .help(isSelected ? "Show all jobs" : "Show only \(title.lowercased()) jobs")
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var summaryChipBackground: Color {
        if isSelected {
            return color.opacity(0.18)
        }
        if isHovering {
            return color.opacity(0.10)
        }
        return Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    }
}

private struct EmptyQueueView: View {
    let workflow: EncodingWorkflow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.teal)
            VStack(spacing: 5) {
                Text("No input files yet")
                    .font(.title3.weight(.semibold))
                Text("Use Add Files or Add Folder to collect \(workflow.title.lowercased()) files for batch encoding.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropTargetOverlay: View {
    let workflow: EncodingWorkflow

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.teal.opacity(0.14))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))

            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 42, weight: .semibold))
                Text("Drop \(workflow.title.lowercased()) files or folders")
                    .font(.headline)
            }
            .foregroundStyle(.teal)
        }
    }
}

private struct EmptyFilteredQueueView: View {
    let hiddenCount: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            VStack(spacing: 5) {
                Text("No queued files match the active filters")
                    .font(.title3.weight(.semibold))
                Text(
                    "\(hiddenCount) queued file\(hiddenCount == 1 ? "" : "s") will return when its format is re-enabled."
                )
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyJobFilterView: View {
    let filterTitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            VStack(spacing: 5) {
                Text("No \(filterTitle.lowercased()) jobs")
                    .font(.title3.weight(.semibold))
                Text("Click the selected badge again to show all encoding jobs.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderPickerControl: View {
    let title: String
    let detail: String?
    let systemImage: String
    let buttonTitle: String
    let disabled: Bool
    let secondaryButtonTitle: String?
    let secondarySystemImage: String
    let secondaryDisabled: Bool
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    init(
        title: String,
        detail: String?,
        systemImage: String,
        buttonTitle: String,
        disabled: Bool,
        secondaryButtonTitle: String? = nil,
        secondarySystemImage: String = "xmark.circle",
        secondaryDisabled: Bool = true,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.buttonTitle = buttonTitle
        self.disabled = disabled
        self.secondaryButtonTitle = secondaryButtonTitle
        self.secondarySystemImage = secondarySystemImage
        self.secondaryDisabled = secondaryDisabled
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(.teal)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(title.hasPrefix("No ") ? .secondary : .primary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    action()
                } label: {
                    Label(buttonTitle, systemImage: "folder")
                }
                .disabled(disabled)

                if let secondaryButtonTitle, let secondaryAction {
                    Button(role: .destructive) {
                        secondaryAction()
                    } label: {
                        Label(secondaryButtonTitle, systemImage: secondarySystemImage)
                    }
                    .disabled(secondaryDisabled)
                    .help("Clear the selected source folder view")
                }
            }
        }
    }
}

private struct CenteredStatusView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.teal)
            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
    let operation: FolderSyncOperation

    private var color: Color {
        switch operation.kind {
        case .copyNew, .copyUpdated, .createDirectory:
            .teal
        case .deleteFile, .deleteDirectory:
            .red
        }
    }

    private var symbolName: String {
        switch operation.kind {
        case .createDirectory:
            "folder.badge.plus"
        case .copyNew:
            "doc.badge.plus"
        case .copyUpdated:
            "arrow.clockwise"
        case .deleteFile:
            "trash"
        case .deleteDirectory:
            "folder.badge.minus"
        }
    }

    private var title: String {
        switch operation.kind {
        case .createDirectory:
            "Create folder"
        case .copyNew:
            "Copy new"
        case .copyUpdated:
            "Update"
        case .deleteFile:
            "Delete file"
        case .deleteDirectory:
            "Delete folder"
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
    }
}

private struct MediaCopyCandidateRow: View {
    let candidate: MediaCopyCandidate
    let filter: MediaFileFilter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: filter.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(candidate.hasDestinationConflict ? .orange : .teal)
                .frame(width: 34, height: 34)
                .background(
                    (candidate.hasDestinationConflict ? Color.orange : Color.teal).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.relativePath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if candidate.hasDestinationConflict {
                        Text("EXISTS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                .orange.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }

                    Spacer()

                    Text(candidate.fileSizeBytes.formattedFileSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(candidate.destinationURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    candidate.hasDestinationConflict
                        ? Color.orange.opacity(0.45)
                        : Color(nsColor: .separatorColor).opacity(0.35)
                )
        }
    }
}

private struct MediaRenameItemRow: View {
    let item: MediaRenameItem

    private var stateColor: Color {
        switch item.state {
        case .ready:
            .teal
        case .unchanged:
            Color(nsColor: .secondaryLabelColor)
        case .duplicate:
            .orange
        case .conflict, .invalid:
            .red
        }
    }

    private var stateSymbol: String {
        switch item.state {
        case .ready:
            "checkmark.circle"
        case .unchanged:
            "equal.circle"
        case .duplicate:
            "square.on.square"
        case .conflict:
            "exclamationmark.triangle"
        case .invalid:
            "xmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stateSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 34, height: 34)
                .background(
                    stateColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.originalName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(item.newName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.state.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            stateColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    Spacer()

                    Text(item.fileSizeBytes.formattedFileSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(item.sourceURL.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.state != .ready {
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(stateColor)
                            .lineLimit(1)
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
                .stroke(stateColor.opacity(item.state == .ready ? 0.35 : 0.5))
        }
    }
}

private struct MediaDeleteCandidateRow: View {
    let candidate: MediaDeleteCandidate
    let filter: MediaFileFilter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 34, height: 34)
                .background(
                    Color.red.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.relativePath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(filter.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            .red.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    Spacer()

                    Text(candidate.fileSizeBytes.formattedFileSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(candidate.sourceURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35))
        }
    }
}

private struct MediaCopyWorkflowRow: View {
    let index: Int
    let workflow: MediaCopyWorkflow
    let isRunning: Bool
    let canModify: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: workflow.filter.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(isRunning ? .teal : .indigo)
            .frame(width: 34, height: 34)
            .background(
                (isRunning ? Color.teal : Color.indigo).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("\(index). \(workflow.filter.title)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if workflow.filter.supportsExtensionSelection {
                        Text(
                            workflow.filter
                                .compactExtensionSummary(
                                    selectedExtensions: workflow.selectedExtensions
                                )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }

                    if workflow.fileNameFilter.isActive {
                        Text("Name: \(workflow.fileNameFilter.trimmedQuery)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(workflow.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(workflow.sourceRoot.path(percentEncoded: false)) -> \(workflow.destinationRootPreservingSourceFolder.path(percentEncoded: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button {
                remove()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.gphilHoverBorderless)
            .foregroundStyle(.secondary)
            .disabled(!canModify)
            .help("Remove from queue")
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isRunning
                        ? Color.teal.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.35)
                )
        }
    }
}

private struct InputRow: View {
    let item: AudioInputItem
    let canModify: Bool
    let remove: () -> Void
    let trashSource: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.encodingWorkflow?.symbolName ?? "doc")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(item.encodingWorkflow == .video ? .indigo : .teal)
                .frame(width: 34, height: 34)
                .background(
                    (item.encodingWorkflow == .video ? Color.indigo : Color.teal).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.fileSizeBytes.formattedFileSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.displayDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                trashSource()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.gphilHoverBorderless)
            .foregroundStyle(.red)
            .disabled(!canModify)
            .help("Move source file to Trash")

            Button {
                remove()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.gphilHoverBorderless)
            .foregroundStyle(.secondary)
            .disabled(!canModify)
            .help("Remove from queue")
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
    }
}

private struct JobRow: View {
    let job: EncodeJob
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            stateIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(job.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateColor)
                }

                Text(job.outputURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !job.message.isEmpty {
                    Text(job.message)
                        .font(.caption)
                        .foregroundStyle(job.state == .failed ? .red : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            if job.state == .succeeded {
                Button {
                    reveal()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.gphilHoverBorderless)
                .help("Reveal output")
            }

            if job.state == .failed {
                Button {
                    copyFailureDiagnostic()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.gphilHoverBorderless)
                .foregroundStyle(.red)
                .help("Copy error log")
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    job.state == .failed
                        ? Color.red.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.35))
        }
        .contextMenu {
            if job.state == .failed {
                Button("Copy Error Log") {
                    copyFailureDiagnostic()
                }
            }
        }
    }

    private func copyFailureDiagnostic() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyableDiagnostic, forType: .string)
    }

    private var copyableDiagnostic: String {
        if !job.diagnosticMessage.isEmpty {
            return job.diagnosticMessage
        }

        return [
            "GPhilCoder job \(job.state.label)",
            "Input: \(job.item.url.path(percentEncoded: false))",
            "Output: \(job.outputURL.path(percentEncoded: false))",
            "",
            "Message:",
            job.message,
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private var stateIcon: some View {
        if job.state == .running {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .background(
                    .teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: job.state.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 34, height: 34)
                .background(
                    stateColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .queued:
            .secondary
        case .running:
            .teal
        case .succeeded:
            .green
        case .skipped:
            .orange
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}

private struct SettingValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .fontWeight(.semibold)
        }
    }
}

struct FormatPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
}

private struct WorkflowTabButton: View {
    let tab: WorkflowTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(tab.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 10)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.accessibilityTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct HeaderAppIcon: View {
    var body: some View {
        Group {
            if let image = Self.loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
    }

    private static func loadImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }

        let sourceAssetURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/appicon.png")

        if let image = NSImage(contentsOf: sourceAssetURL) {
            return image
        }

        if let url = Bundle.main.url(forResource: "appicon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }

        return nil
    }
}

extension View {
    func arrowCursorOnHover() -> some View {
        modifier(ArrowCursorModifier())
    }
}

private struct ArrowCursorModifier: ViewModifier {
    @State private var pushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !pushedCursor {
                    NSCursor.arrow.push()
                    pushedCursor = true
                } else if !hovering, pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .onDisappear {
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
    }
}
