import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: EncoderViewModel
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
            .frame(height: 30)
            .background(.bar)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HeaderAppIcon()

            VStack(alignment: .leading, spacing: 2) {
                Text("GPhilCoder")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Batch audio to MP3, Ogg, Opus, FLAC, and WavPack with parallel FFmpeg workers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ToolStatusView()
        }
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 14)
        .background(.bar)
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
                    .disabled(model.inputs.isEmpty || model.isEncoding)

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
                    title: "Active", value: "\(model.activeInputs.count)", symbol: "music.note.list",
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
                    Label("Move active sources to Trash", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.activeInputs.isEmpty || model.isEncoding)
                .help("Move only source files matching the active input filters to the macOS Trash")

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
                        failed: model.failedCount
                    )
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
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.jobs) { job in
                    JobRow(job: job) {
                        model.revealOutput(for: job)
                    }
                }
            }
            .padding(18)
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
                "FLAC is lossless. Higher compression levels can make smaller files, but encoding is slower."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        case .wavpack:
            Text(
                "WavPack output is lossless and preserves high-bit-depth sources. This FFmpeg encoder does not expose a FLAC-style compression level."
            )
            .font(.callout)
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
                Text(model.ffmpegURL == nil ? "\(model.ffmpegSourceTitle) FFmpeg missing" : "\(model.ffmpegSourceTitle) FFmpeg ready")
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
            .help("Choose whether encoding uses the app-bundled FFmpeg or the FFmpeg installed on this Mac.")

            Button {
                model.refreshFFmpeg()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh FFmpeg detection")
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

    var body: some View {
        HStack(spacing: 8) {
            SummaryChip(value: completed, symbol: "checkmark", color: .green)
            SummaryChip(value: running, symbol: "waveform", color: .teal)
            SummaryChip(value: queued, symbol: "clock", color: .secondary)
            SummaryChip(value: skipped, symbol: "forward.end", color: .orange)
            SummaryChip(value: failed, symbol: "xmark", color: .red)
        }
    }
}

private struct SummaryChip: View {
    let value: Int
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
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
            job.message
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
