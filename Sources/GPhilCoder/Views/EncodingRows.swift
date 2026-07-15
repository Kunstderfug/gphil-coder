import AppKit
import GPhilCoderCore
import SwiftUI

struct InputFilterSheet: View {
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

struct JobSummaryStrip: View {
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

struct EmptyQueueView: View {
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

struct DropTargetOverlay: View {
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

struct EmptyFilteredQueueView: View {
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

struct EmptyJobFilterView: View {
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

struct InputRow: View {
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

struct JobRow: View {
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

                if let progressFraction = job.progressFraction, job.state == .running {
                    HStack(spacing: 8) {
                        ProgressView(value: progressFraction)
                            .progressViewStyle(.linear)
                        Text(progressLabel(for: progressFraction))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(stateColor)
                            .frame(width: 42, alignment: .trailing)
                        if let estimatedSecondsRemaining = job.estimatedSecondsRemaining {
                            Text("ETA \(etaLabel(for: estimatedSecondsRemaining))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 74, alignment: .trailing)
                        }
                    }
                    .accessibilityLabel("Encoding progress")
                    .accessibilityValue(progressAccessibilityValue(for: progressFraction))
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
            "GPhil MediaFlow job \(job.state.label)",
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

    private func progressLabel(for fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func etaLabel(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    private func progressAccessibilityValue(for fraction: Double) -> String {
        let progress = progressLabel(for: fraction)
        guard let estimatedSecondsRemaining = job.estimatedSecondsRemaining else { return progress }
        return "\(progress), estimated time remaining \(etaLabel(for: estimatedSecondsRemaining))"
    }
}