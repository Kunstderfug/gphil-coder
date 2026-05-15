import AppKit
import SwiftUI

struct RestoreFromBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                controls
                    .frame(width: 330)

                Divider()

                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 880, height: 680)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore From Backup")
                    .font(.title3.weight(.semibold))
                Text("Infer original folder paths from a structured backup volume.")
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
        .padding(20)
        .background(.bar)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Folders") {
                VStack(alignment: .leading, spacing: 12) {
                    RestoreFolderRow(
                        title: "Deleted files",
                        path: model.restoreDeletedFolder?.path(percentEncoded: false),
                        systemImage: "trash",
                        isDisabled: model.isRestorePlanning || model.isRestoringFromPlan
                    ) {
                        model.chooseRestoreDeletedFolder()
                    }

                    RestoreFolderRow(
                        title: "Backup root",
                        path: model.restoreBackupRoot?.path(percentEncoded: false),
                        systemImage: "externaldrive",
                        isDisabled: model.isRestorePlanning || model.isRestoringFromPlan
                    ) {
                        model.chooseRestoreBackupRoot()
                    }

                    RestoreFolderRow(
                        title: "Restore root",
                        path: model.restoreDestinationRoot?.path(percentEncoded: false),
                        systemImage: "folder.badge.gearshape",
                        isDisabled: model.isRestorePlanning || model.isRestoringFromPlan
                    ) {
                        model.chooseRestoreDestinationRoot()
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Matching") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Match by", selection: $model.restoreMatchMode) {
                        ForEach(RestoreMatchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(model.isRestorePlanning || model.isRestoringFromPlan)

                    Text(model.restoreMatchMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Hashing", selection: $model.restoreHashMode) {
                        ForEach(RestoreHashMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(model.isRestorePlanning || model.isRestoringFromPlan)

                    Text(model.restoreHashMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Copy from", selection: $model.restoreCopySource) {
                        ForEach(RestoreCopySource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .disabled(model.isRestorePlanning || model.isRestoringFromPlan)

                    Toggle("Include hidden files", isOn: $model.restoreIncludeHidden)
                        .disabled(model.isRestorePlanning || model.isRestoringFromPlan)

                    Toggle("Overwrite existing restore paths", isOn: $model.restoreOverwriteExisting)
                        .disabled(model.isRestorePlanning || model.isRestoringFromPlan)
                }
                .padding(.vertical, 4)
            }

            Spacer()

            VStack(spacing: 10) {
                if model.isRestorePlanning {
                    Button {
                        model.cancelBackupRestorePlan()
                    } label: {
                        Label("Stop search", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help("Stop scanning and keep the partial results shown so far")
                } else {
                    Button {
                        model.buildBackupRestorePlan()
                    } label: {
                        Label("Build restore plan", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canBuildBackupRestorePlan)
                }

                Button {
                    model.applyBackupRestorePlan()
                } label: {
                    Label("Restore matched files", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canApplyBackupRestorePlan)
            }
            .controlSize(.large)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                RestoreSummaryChip(
                    title: "Restored",
                    value: model.restorePlanAlreadyRestoredCount,
                    color: .teal
                )
                RestoreSummaryChip(
                    title: "Backup Match",
                    value: model.restorePlanMatchedCount,
                    color: .green
                )
                RestoreSummaryChip(
                    title: "Target Exists",
                    value: model.restorePlanConflictCount,
                    color: .orange
                )
                RestoreSummaryChip(
                    title: "Ambiguous",
                    value: model.restorePlanAmbiguousCount,
                    color: .yellow
                )
                RestoreSummaryChip(
                    title: "Missing",
                    value: model.restorePlanMissingCount,
                    color: .red
                )

                Spacer()

                if model.canExportRestoreUnresolvedItems, !model.restorePlanRecords.isEmpty {
                    Button {
                        model.exportRestoreUnresolvedItems()
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export unresolved files as JSON")
                }

                if model.isRestorePlanning || model.isRestoringFromPlan {
                    Image(systemName: model.isRestorePlanning ? "magnifyingglass" : "arrow.down.doc")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if model.restorePlanDeletedCount > 0 {
                RestoreResolutionSummaryBar(
                    deleted: model.restorePlanDeletedCount,
                    restored: model.restorePlanAlreadyRestoredCount,
                    unresolved: model.restorePlanUnresolvedCount
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            if let scanSummary = model.restorePlanScanSummary {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Scan: \(scanSummary.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, model.isRestorePlanning || model.isRestoringFromPlan ? 8 : 14)
            }

            if model.isRestorePlanning || model.isRestoringFromPlan {
                RestorePlanProgressPanel(
                    progress: model.restorePlanProgress,
                    isRestoring: model.isRestoringFromPlan
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }

            Divider()

            if model.restorePlanRecords.isEmpty {
                if !model.restorePlanLiveUnresolvedItems.isEmpty {
                    RestoreLiveUnresolvedList(
                        items: model.restorePlanLiveUnresolvedItems,
                        deletedCount: model.restorePlanDeletedCount,
                        restoredCount: model.restorePlanAlreadyRestoredCount,
                        phase: model.restorePlanProgress?.phase
                    ) {
                        model.exportRestoreUnresolvedItems()
                    }
                } else {
                    RestorePlanEmptyState(
                        isScanning: model.isRestorePlanning,
                        progress: model.restorePlanProgress
                    )
                }
            } else {
                List(model.restorePlanRecords) { record in
                    RestorePlanRecordRow(record: record)
                }
                .listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("The plan copies files back; it does not delete anything from the deleted folder or backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct RestoreResolutionSummaryBar: View {
    let deleted: Int
    let restored: Int
    let unresolved: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Deleted \(deleted.formatted())", systemImage: "trash")
                Text("Restored \(restored.formatted())")
                    .foregroundStyle(.teal)
                Text("Unresolved \(unresolved.formatted())")
                    .foregroundStyle(unresolved == 0 ? .green : .orange)
                Spacer()
            }
            .font(.caption.weight(.semibold))

            ProgressView(value: Double(restored), total: Double(max(deleted, 1)))
                .tint(unresolved == 0 ? .green : .teal)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14))
        )
    }
}

private struct RestoreLiveUnresolvedList: View {
    let items: [RestoreUnresolvedFile]
    let deletedCount: Int
    let restoredCount: Int
    let phase: RestorePlanProgressPhase?
    let export: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(title, systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.semibold))

                Spacer()

                Button {
                    export()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Export this unresolved file list as JSON")

                Text("\(items.count.formatted()) of \(deletedCount.formatted())")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            HStack(spacing: 12) {
                Text("Restored \(restoredCount.formatted())")
                    .foregroundStyle(.teal)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider()

            List(items) { item in
                RestoreLiveUnresolvedRow(item: item)
            }
            .listStyle(.inset)
        }
    }

    private var title: String {
        switch phase {
        case .matching:
            "Still unresolved in backup search"
        case .scanningBackup:
            "Unresolved after Restore root"
        default:
            "Currently unresolved files"
        }
    }

    private var subtitle: String {
        switch phase {
        case .matching:
            "Waiting for backup classification \(items.count.formatted())"
        case .scanningBackup:
            "Waiting for backup search \(items.count.formatted())"
        default:
            "Needs restore or backup match \(items.count.formatted())"
        }
    }
}

private struct RestoreLiveUnresolvedRow: View {
    let item: RestoreUnresolvedFile

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "doc")
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.size.formattedFileSize)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(item.deletedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let matchName = item.matchName {
                    Text("Searching as \(matchName)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct RestorePlanProgressPanel: View {
    let progress: RestorePlanProgress?
    let isRestoring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if let progress {
                    Text(progress.countText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let progress, let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(total))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16))
        )
    }

    private var title: String {
        if let progress {
            progress.title
        } else {
            isRestoring ? "Restoring files" : "Preparing scan"
        }
    }

    private var detail: String {
        if let progress {
            progress.detail
        } else {
            isRestoring ? "Copying matched files back to the restore root." : "Preparing folders."
        }
    }

    private var systemImage: String {
        if isRestoring {
            return "arrow.down.doc"
        }
        switch progress?.phase {
        case .scanningDeleted:
            return "trash"
        case .scanningRestore:
            return "folder.badge.checkmark"
        case .checkingRestore:
            return "checklist.checked"
        case .scanningBackup:
            return "externaldrive"
        case .matching:
            return "point.3.connected.trianglepath.dotted"
        case nil:
            return "magnifyingglass"
        }
    }
}

private struct RestoreFolderRow: View {
    let title: String
    let path: String?
    let systemImage: String
    let isDisabled: Bool
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Text(path ?? "Choose folder")
                    .font(.caption)
                    .foregroundStyle(path == nil ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    choose()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
                .help("Choose \(title)")
            }
        }
    }
}

private struct RestoreSummaryChip: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("\(value)")
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(width: 96, alignment: .leading)
    }
}

private struct RestorePlanEmptyState: View {
    let isScanning: Bool
    let progress: RestorePlanProgress?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isScanning ? "magnifyingglass" : "externaldrive.badge.timemachine")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.teal)
            Text(isScanning ? progress?.title ?? "Scanning backup tree" : "No restore plan yet")
                .font(.title3.weight(.semibold))
            Text(
                isScanning
                    ? progress?.detail ?? "Large network volumes can take a while."
                    : "Choose the deleted folder, backup root, and restore root, then build a plan."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RestorePlanRecordRow: View {
    let record: RestorePlanRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)
                .background(
                    statusColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(record.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                if let restorePath = record.restoreURL?.path(percentEncoded: false) {
                    Text(restorePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(record.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if (record.status == .ambiguous || record.status == .alreadyRestored),
                    record.candidates.count > 1,
                    let firstCandidate = record.candidates.first
                {
                    Text("Candidates: \(record.candidates.count), first \(firstCandidate.path(percentEncoded: false))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch record.status {
        case .alreadyRestored:
            .teal
        case .matched:
            .green
        case .matchedConflict:
            .orange
        case .ambiguous:
            .yellow
        case .missing:
            .red
        }
    }

    private var symbolName: String {
        switch record.status {
        case .alreadyRestored:
            "checkmark.circle.fill"
        case .matched:
            "checkmark"
        case .matchedConflict:
            "exclamationmark.triangle.fill"
        case .ambiguous:
            "questionmark"
        case .missing:
            "xmark"
        }
    }
}
