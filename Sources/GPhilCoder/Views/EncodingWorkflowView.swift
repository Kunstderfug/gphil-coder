import AppKit
import GPhilCoderCore
import SwiftUI
import UniformTypeIdentifiers

struct EncodingWorkflowView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: EncoderViewModel
    @Binding var showingInputFilterSheet: Bool
    @Binding var isEncodingDropTargeted: Bool

    var body: some View {
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
