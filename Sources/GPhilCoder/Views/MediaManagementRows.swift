import AppKit
import GPhilCoderCore
import SwiftUI

struct MediaCopyCandidateRow: View {
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

struct MediaRenameItemRow: View {
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

struct MediaDeleteCandidateRow: View {
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

struct MediaCopyWorkflowRow: View {
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
