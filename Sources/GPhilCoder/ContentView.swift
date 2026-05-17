import AppKit
import GPhilCoderCore
import SwiftUI

private enum WorkflowTab: Hashable {
    case audioEncoding
    case fileManagement
}

private enum MediaCopyPreviewMode: Hashable {
    case plan
    case queue
}

struct ContentView: View {
    @EnvironmentObject private var model: EncoderViewModel
    @State private var selectedWorkflowTab: WorkflowTab = .audioEncoding
    @State private var selectedMediaCopyPreviewMode: MediaCopyPreviewMode = .plan
    @State private var showingInputFilterSheet = false
    @State private var showingRestoreFromBackupSheet = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titlebarSpacer
                topBar
                Divider()
                TabView(selection: $selectedWorkflowTab) {
                    audioEncodingWorkflow
                        .tabItem {
                            Label("Audio Encoding", systemImage: "waveform")
                        }
                        .tag(WorkflowTab.audioEncoding)

                    fileManagementWorkflow
                        .tabItem {
                            Label("File Management", systemImage: "folder")
                        }
                        .tag(WorkflowTab.fileManagement)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .accentColor(.teal)
        .sheet(isPresented: $showingInputFilterSheet) {
            InputFilterSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showingRestoreFromBackupSheet) {
            RestoreFromBackupSheet()
                .environmentObject(model)
        }
    }

    private var titlebarSpacer: some View {
        Color.clear
            .frame(height: 10)
            .background(.bar)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HeaderAppIcon()

            VStack(alignment: .leading, spacing: 2) {
                Text("GPhil Coder")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(
                    "Batch audio encoding and filtered media copy workflows"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            ToolStatusView()
        }
        .padding(.horizontal, 22)
        // .padding(.top, 4)
        .padding(.bottom, 14)
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

    private var fileManagementWorkflow: some View {
        HStack(spacing: 0) {
            mediaCopySetupPanel
                .frame(width: 340)

            Divider()

            mediaCopyResultsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mediaCopySetupPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Source") {
                FolderPickerControl(
                    url: model.mediaCopySourceRoot,
                    placeholder: "No source folder selected",
                    systemImage: "folder.badge.plus",
                    buttonTitle: "Choose source",
                    disabled: model.isMediaCopyBusy
                ) {
                    model.chooseMediaCopySourceRoot()
                }
                .padding(.vertical, 4)
            }

            GroupBox("Destination") {
                FolderPickerControl(
                    url: model.mediaCopyDestinationRoot,
                    placeholder: "No destination folder selected",
                    systemImage: "externaldrive",
                    buttonTitle: "Choose destination",
                    disabled: model.isMediaCopyBusy
                ) {
                    model.chooseMediaCopyDestinationRoot()
                }
                .padding(.vertical, 4)
            }

            GroupBox("Filter") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Media type", selection: $model.mediaCopyFilter) {
                        ForEach(MediaFileFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.symbolName)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isMediaCopyBusy)
                    .arrowCursorOnHover()

                    Text(model.mediaCopyFilter.readableExtensions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Plan") {
                VStack(alignment: .leading, spacing: 9) {
                    StatLine(
                        title: "Matched",
                        value: "\(model.mediaCopyMatchedCount)",
                        symbol: model.mediaCopyFilter.symbolName,
                        color: .teal
                    )
                    StatLine(
                        title: "Existing",
                        value: "\(model.mediaCopyConflictCount)",
                        symbol: "exclamationmark.triangle",
                        color: model.mediaCopyConflictCount > 0 ? .orange : .secondary
                    )
                    StatLine(
                        title: "Total size",
                        value: model.mediaCopyTotalSize.formattedFileSize,
                        symbol: "externaldrive",
                        color: .indigo
                    )

                    if let plan = model.mediaCopyPlan, plan.directoryCount > 0 {
                        StatLine(
                            title: "Folders",
                            value: "\(plan.directoryCount)",
                            symbol: "folder",
                            color: .teal
                        )
                    }

                    if let plan = model.mediaCopyPlan, plan.conflictCount > 0 {
                        Text(
                            "\(plan.copyableWithoutOverwriteCount) file\(plan.copyableWithoutOverwriteCount == 1 ? "" : "s") can be copied without replacing existing destination files."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            if let progress = model.mediaCopyProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionCompleted)
                    HStack {
                        Text("\(progress.completed) of \(progress.total)")
                            .monospacedDigit()
                        Spacer()
                        Text("\(progress.copied) copied")
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

            Spacer()

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
                }
            }

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
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var mediaCopyResultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("File Copy Plan")
                        .font(.title3.weight(.semibold))
                    Text(mediaCopySubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $selectedMediaCopyPreviewMode) {
                    Text("Plan").tag(MediaCopyPreviewMode.plan)
                    Text("Queue").tag(MediaCopyPreviewMode.queue)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                .disabled(model.isMediaCopyBusy)
                .arrowCursorOnHover()

                if selectedMediaCopyPreviewMode == .plan,
                    let plan = model.mediaCopyPlan,
                    plan.hasCopyableContent
                {
                    HStack(spacing: 8) {
                        FormatPill(text: plan.filter.title.uppercased())
                        FormatPill(text: "\(plan.candidates.count) FILES")
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
        if selectedMediaCopyPreviewMode == .queue {
            mediaCopyQueueContent
        } else if model.isMediaCopyScanning {
            CenteredStatusView(
                symbol: "magnifyingglass",
                title: "Scanning folders",
                detail: "Checking \(model.mediaCopyFilter.fileTypeName) files and destination conflicts."
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

                    if plan.candidates.count > model.mediaCopyPreviewItems.count {
                        Text(
                            "\(plan.candidates.count - model.mediaCopyPreviewItems.count) more file\(plan.candidates.count - model.mediaCopyPreviewItems.count == 1 ? "" : "s") hidden from preview."
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

    private var mediaCopySubtitle: String {
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
                "\(plan.candidates.count) matched, \(plan.conflictCount) already exist in the destination."
        }

        return "\(plan.candidates.count) matched, no destination conflicts."
    }

    private var mediaCopyProgressDetail: String {
        guard let progress = model.mediaCopyProgress else {
            return "Preparing copy."
        }

        return
            "\(progress.completed) of \(progress.total) processed, \(progress.copied) copied, \(progress.skippedExisting) skipped, \(progress.failed) failed."
    }

    private var libraryPanel: some View {
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
                    symbol: "music.note.list",
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

            Spacer()

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

                Button {
                    showingRestoreFromBackupSheet = true
                } label: {
                    Label("Plan restore from backup", systemImage: "externaldrive.badge.icloud")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isEncoding)
                .help("Infer original folders from a structured backup volume")
            }
        }
        .padding(18)
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
            .help("Choose input audio formats")
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
    }

    private var inputList: some View {
        Group {
            if model.inputs.isEmpty {
                EmptyQueueView()
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
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $model.outputMode) {
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

                            Toggle("Preserve subfolders", isOn: $model.preserveSubfolders)
                                .disabled(model.isEncoding)
                        }
                    } else {
                        Text(
                            "\(model.outputFormat.title) files are written next to each source file. Files added from nested folders stay in those folders."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Encoding") {
                VStack(alignment: .leading, spacing: 13) {
                    Picker("Output format", selection: $model.outputFormat) {
                        ForEach(AudioOutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isEncoding)

                    Text(model.outputFormat.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    formatEncodingControls

                    Stepper(value: $model.parallelJobs, in: 1...model.processorLimit) {
                        SettingValue(title: "Parallel jobs", value: "\(model.parallelJobs)")
                    }
                    .disabled(model.isEncoding)

                    Stepper(value: $model.ffmpegThreads, in: 0...model.processorLimit) {
                        SettingValue(
                            title: "FFmpeg threads",
                            value: model.ffmpegThreads == 0 ? "Auto" : "\(model.ffmpegThreads)"
                        )
                    }
                    .disabled(model.isEncoding)

                    Toggle(
                        "Overwrite existing \(model.outputFormat.title) files",
                        isOn: $model.overwriteExisting
                    )
                    .disabled(model.isEncoding)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Format") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        FormatPill(text: "AUDIO")
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FormatPill(text: model.outputFormat.title)
                    }
                    Text(
                        "The queue keeps every supported audio file you add. Input filters choose which queued formats are visible and sent to FFmpeg's \(model.selectedEncoderName) encoder."
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
                }
                .padding(.vertical, 4)
            }

            Spacer()

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
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var formatEncodingControls: some View {
        switch model.outputFormat {
        case .mp3:
            Picker("MP3 mode", selection: $model.mp3Mode) {
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
            Picker("Ogg mode", selection: $model.oggMode) {
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
                Picker("Bitrate", selection: $model.oggBitrateKbps) {
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
                Picker("Quality", selection: $model.oggQuality) {
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
            Picker("Opus mode", selection: $model.opusRateMode) {
                ForEach(OpusEncodingOptions.RateMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isEncoding)
            .arrowCursorOnHover()

            Picker("Bitrate", selection: $model.opusBitrateKbps) {
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
            Picker("Compression", selection: $model.flacCompressionLevel) {
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

    private var multichannelSplitToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Split oversized multichannel sources",
                isOn: $model.splitOversizedMultichannel
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
            Picker("Quality", selection: $model.vbrQuality) {
                ForEach(MP3EncodingOptions.vbrQualities, id: \.self) { quality in
                    Text(MP3EncodingOptions.vbrQualityLabel(quality)).tag(quality)
                }
            }
            .disabled(model.isEncoding)

        case .cbr:
            Picker("Bitrate", selection: $model.cbrBitrateKbps) {
                ForEach(MP3EncodingOptions.bitrateKbps, id: \.self) { bitrate in
                    Text("\(bitrate) kbps").tag(bitrate)
                }
            }
            .disabled(model.isEncoding)

        case .abr:
            Picker("Target", selection: $model.abrBitrateKbps) {
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
                systemName: model.ffmpegURL == nil ? "exclamationmark.triangle.fill" : "info.circle"
            )
            .foregroundStyle(model.ffmpegURL == nil ? .orange : .secondary)
            Text(model.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var outputRouteDescription: String {
        switch model.outputMode {
        case .sourceFolders:
            return "Write \(model.outputFormat.title) files beside each source file."
        case .exportFolder:
            if let exportFolder = model.exportFolder {
                let suffix = model.preserveSubfolders ? " and preserve nested folders." : "."
                return
                    "Write \(model.outputFormat.title) files to \(exportFolder.lastPathComponent)\(suffix)"
            }
            return "Choose a destination folder before encoding."
        }
    }

    private var queueSubtitle: String {
        if model.jobs.isEmpty {
            return model.inputs.isEmpty
                ? "Drop into the workflow by adding files or folders."
                : "\(model.activeInputs.count) of \(model.inputs.count) queued audio file\(model.inputs.count == 1 ? "" : "s") active."
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

private struct ToolStatusView: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.ffmpegURL == nil ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .foregroundStyle(model.ffmpegURL == nil ? .orange : .green)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    model.ffmpegURL == nil
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
            }

            Picker("FFmpeg", selection: $model.ffmpegSourcePreference) {
                ForEach(FFmpegSourcePreference.allCases) { source in
                    Text(sourceLabel(source))
                        .tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)
            .disabled(model.isEncoding)
            .help(
                "Choose whether encoding uses the app-bundled FFmpeg or the FFmpeg installed on this Mac."
            )

            Button {
                model.refreshFFmpeg()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
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
                Button {
                    model.sendTestNotification()
                } label: {
                    Text("Test")
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
        switch model.notificationPermission {
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
                    Text("Choose which file extensions are accepted when adding files or folders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
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
            }

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
                isSelected
                    ? color.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? color.opacity(0.7) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(value == 0 && !isSelected)
        .help(isSelected ? "Show all jobs" : "Show only \(title.lowercased()) jobs")
    }
}

private struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.teal)
            VStack(spacing: 5) {
                Text("No input files yet")
                    .font(.title3.weight(.semibold))
                Text("Use Add Files or Add Folder to collect audio files for batch encoding.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let url: URL?
    let placeholder: String
    let systemImage: String
    let buttonTitle: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(.teal)
                    .frame(width: 18)

                Text(url?.path(percentEncoded: false) ?? placeholder)
                    .font(.callout)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button {
                action()
            } label: {
                Label(buttonTitle, systemImage: "folder")
            }
            .disabled(disabled)
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
            .buttonStyle(.borderless)
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
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 34, height: 34)
                .background(
                    .teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(!canModify)
            .help("Move source file to Trash")

            Button {
                remove()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
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
                .buttonStyle(.borderless)
                .help("Reveal output")
            }

            if job.state == .failed {
                Button {
                    copyFailureDiagnostic()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
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

private struct FormatPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
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
    fileprivate func arrowCursorOnHover() -> some View {
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
