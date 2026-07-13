import GPhilCoderCore
import SwiftUI

enum FolderSyncResultsSection: String, CaseIterable, Identifiable {
    case plan
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan:
            "Plan"
        case .history:
            "History & Recovery"
        }
    }
}

struct FolderSyncHistoryView: View {
    @ObservedObject var model: EncoderViewModel
    @State private var pendingConfirmation: FolderSyncHistoryConfirmation?

    private var recoveryGroups: [FolderSyncRecoveryGroup] {
        Dictionary(grouping: model.syncRecoveryRecords, by: \.runID)
            .map { FolderSyncRecoveryGroup(runID: $0.key, records: $0.value) }
            .sorted { $0.latestSequence > $1.latestSequence }
    }

    private var orphanedRecoveryGroups: [FolderSyncRecoveryGroup] {
        let historyRunIDs = Set(model.syncHistory.map(\.id))
        return recoveryGroups.filter { !historyRunIDs.contains($0.runID) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                historyHeader

                if !model.syncRecoveryRecords.isEmpty {
                    recoveryOverview
                }

                if model.syncHistory.isEmpty {
                    emptyHistoryView
                } else {
                    ForEach(model.syncHistory) { run in
                        FolderSyncHistoryRunCard(
                            run: run,
                            recoveryRecords: recoveryRecords(for: run.id),
                            canRollback: model.canRollbackFolderSyncRun(run),
                            canRetry: model.canRetryFolderSyncRun(run),
                            requestRollback: {
                                pendingConfirmation = .rollback(
                                    runID: run.id,
                                    title: run.pairSummary,
                                    recordCount: recoveryRecords(for: run.id).count
                                )
                            },
                            retryFailures: {
                                model.retryFolderSyncRun(run.id)
                            }
                        )
                    }
                }

                if !orphanedRecoveryGroups.isEmpty {
                    orphanedRecoverySection
                }
            }
            .padding(18)
        }
        .alert(item: $pendingConfirmation, content: confirmationAlert)
    }

    private var historyHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent Runs")
                    .font(.headline)
                Text("Review durable outcomes and recoverable changes from manual and automatic syncs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !model.syncHistory.isEmpty {
                Button(role: .destructive) {
                    pendingConfirmation = .clearHistory
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(model.isFolderSyncBusy)
                .help("Clear history metadata without deleting retained recovery files or records")
                .accessibilityHint(
                    "Shows a warning before removing history metadata. Recovery files and records remain available."
                )
            }
        }
    }

    private var recoveryOverview: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title3)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "\(model.syncRecoveryRecords.count) active recovery record\(model.syncRecoveryRecords.count == 1 ? "" : "s")"
                )
                .font(.callout.weight(.semibold))

                Text(
                    "Rollback remains available until these records are resolved, even if history metadata is cleared."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.teal.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.syncRecoveryRecords.count) active Folder Sync recovery record\(model.syncRecoveryRecords.count == 1 ? "" : "s"). Rollback remains available."
        )
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No folder sync history")
                .font(.headline)
            Text(
                model.syncRecoveryRecords.isEmpty
                    ? "Completed and no-change runs will appear here."
                    : "History metadata is empty. Retained recovery records are still available below."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }

    private var orphanedRecoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("Active Recovery")
                .font(.headline)
            Text(
                "These recovery records remain after their run metadata was cleared. Rolling back still uses the retained journal and files."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(orphanedRecoveryGroups) { group in
                FolderSyncRecoveryGroupCard(
                    group: group,
                    isBusy: model.isFolderSyncBusy,
                    requestRollback: {
                        pendingConfirmation = .rollback(
                            runID: group.runID,
                            title: "retained run \(group.shortRunID)",
                            recordCount: group.records.count
                        )
                    }
                )
            }
        }
    }

    private func recoveryRecords(for runID: UUID) -> [FolderSyncRecoveryRecord] {
        model.syncRecoveryRecords
            .filter { $0.runID == runID }
            .sorted { $0.sequence < $1.sequence }
    }

    private func confirmationAlert(
        _ confirmation: FolderSyncHistoryConfirmation
    ) -> Alert {
        switch confirmation {
        case .clearHistory:
            Alert(
                title: Text("Clear Folder Sync History?"),
                message: Text(
                    "This removes Folder Sync history metadata only. Retained recovery files and records are not deleted; they remain available here under Active Recovery for rollback."
                ),
                primaryButton: .destructive(Text("Clear History")) {
                    model.clearFolderSyncHistory()
                },
                secondaryButton: .cancel()
            )
        case .rollback(let runID, let title, let recordCount):
            Alert(
                title: Text("Roll Back \(title)?"),
                message: Text(
                    "Rollback will process \(recordCount) recovery record\(recordCount == 1 ? "" : "s"), restore retained prior items, and remove unchanged items created by this run. Items changed since the run will be kept."
                ),
                primaryButton: .destructive(Text("Roll Back")) {
                    model.rollbackFolderSyncRun(runID)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct FolderSyncHistoryRunCard: View {
    let run: FolderSyncHistoryRun
    let recoveryRecords: [FolderSyncRecoveryRecord]
    let canRollback: Bool
    let canRetry: Bool
    let requestRollback: () -> Void
    let retryFailures: () -> Void

    @State private var showsItems = false
    @State private var showsRecoveryRecords = false
    @State private var showsRollbackItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            runHeader
            countSummary

            Divider()

            pairSummary
            settingsSummary

            if let rollback = run.rollback {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Label("Rollback Result", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.teal)
                        Spacer()
                        Text("\(rollback.restored) restored")
                        if rollback.skipped > 0 {
                            Text("\(rollback.skipped) skipped")
                        }
                        if rollback.failed > 0 {
                            Text("\(rollback.failed) failed")
                        }
                    }
                    .font(.caption)

                    DisclosureGroup(isExpanded: $showsRollbackItems) {
                        LazyVStack(spacing: 7) {
                            ForEach(rollback.items, id: \.recordID) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.outcome.historySymbolName)
                                        .foregroundStyle(item.outcome.historyColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.targetPath)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(item.message)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(
                                    "Rollback \(item.outcome.rawValue), \(item.targetPath). \(item.message)"
                                )
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(
                            "Completed \(rollback.completedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(
                    Color.teal.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }

            if run.isNoChange {
                Label("No changes were needed", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No-change run. No files were modified.")
            } else {
                DisclosureGroup(isExpanded: $showsItems) {
                    LazyVStack(spacing: 8) {
                        ForEach(run.items) { item in
                            FolderSyncHistoryItemRow(item: item)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Item Outcomes (\(run.items.count))")
                        .font(.callout.weight(.semibold))
                }
                .accessibilityHint("Expands the per-item planned operations and final outcomes")
            }

            if !recoveryRecords.isEmpty {
                DisclosureGroup(isExpanded: $showsRecoveryRecords) {
                    LazyVStack(spacing: 8) {
                        ForEach(recoveryRecords) { record in
                            FolderSyncRecoveryRecordRow(record: record)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Recovery Records (\(recoveryRecords.count))")
                        .font(.callout.weight(.semibold))
                }
                .accessibilityHint("Expands the active rollback records for this run")
            }

            if !recoveryRecords.isEmpty || !run.retryCandidates.isEmpty {
                actionRow
            }
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2))
        }
    }

    private var runHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.trigger.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(run.summaryColor)
                .frame(width: 32, height: 32)
                .background(
                    run.summaryColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(run.trigger.title)
                        .font(.callout.weight(.semibold))
                    Text(run.resultTitle.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(run.summaryColor)
                }

                Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Started \(run.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(run.pairs.count) pair\(run.pairs.count == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(run.trigger.title) folder sync, \(run.resultTitle), completed \(run.completedAt.formatted(date: .abbreviated, time: .shortened)), \(run.pairs.count) pair\(run.pairs.count == 1 ? "" : "s")."
        )
    }

    private var countSummary: some View {
        HStack(spacing: 7) {
            FolderSyncHistoryCountBadge(
                title: "Planned",
                value: run.counts.planned,
                color: .indigo
            )
            FolderSyncHistoryCountBadge(
                title: "Succeeded",
                value: run.counts.successful,
                color: .green
            )
            FolderSyncHistoryCountBadge(
                title: "Skipped",
                value: run.counts.skipped,
                color: .secondary
            )
            FolderSyncHistoryCountBadge(
                title: "Failed",
                value: run.counts.failed,
                color: .orange
            )
            FolderSyncHistoryCountBadge(
                title: "Cancelled",
                value: run.counts.cancelled,
                color: .red
            )
            if run.unresolvedOutcomeCount > 0 {
                FolderSyncHistoryCountBadge(
                    title: "Review",
                    value: run.unresolvedOutcomeCount,
                    color: .orange
                )
            }
        }
    }

    private var pairSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Pairs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(run.pairs, id: \.id) { pair in
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.title)
                        .font(.caption.weight(.medium))
                    Text("Origin: \(pair.originPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Destination: \(pair.destinationPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Pair \(pair.title). Origin \(pair.originPath). Destination \(pair.destinationPath)."
                )
            }
        }
    }

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(run.settings.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings. \(run.settings.summary)")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if !recoveryRecords.isEmpty {
                Button {
                    requestRollback()
                } label: {
                    Label("Roll Back Run", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canRollback)
                .help(
                    canRollback
                        ? "Restore retained prior items and undo unchanged items created by this run"
                        : "Rollback is unavailable while another Folder Sync operation is active"
                )
                .accessibilityHint(
                    "Shows a confirmation before processing \(recoveryRecords.count) recovery record\(recoveryRecords.count == 1 ? "" : "s")."
                )
            }

            if !run.retryCandidates.isEmpty {
                Button {
                    retryFailures()
                } label: {
                    Label("Retry Failures", systemImage: "arrow.clockwise")
                }
                .disabled(!canRetry)
                .help(
                    "Prepare a new reviewed plan with only \(run.retryCandidates.count) eligible failed or cancelled item\(run.retryCandidates.count == 1 ? "" : "s")"
                )
                .accessibilityHint(
                    "Successful and ineligible items will not be repeated."
                )
            }

            Spacer()
        }
    }
}

private struct FolderSyncHistoryCountBadge: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            color.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct FolderSyncHistoryItemRow: View {
    let item: FolderSyncHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.historyOutcomeSymbolName)
                .foregroundStyle(item.historyOutcomeColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.relativePath)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.kind.historyTitle.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(item.historyOutcomeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.historyOutcomeColor)
                }

                Text(item.destinationPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let outcomeMessage = item.outcomeMessage, !outcomeMessage.isEmpty {
                    Text(outcomeMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recovery = item.recovery {
                    Label(recovery.mechanism.historyDescription, systemImage: "archivebox")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.teal)
                        .accessibilityLabel(
                            "Recovery available. \(recovery.mechanism.historyDescription)."
                        )
                }
            }

            if item.fileSizeBytes > 0 {
                Text(item.fileSizeBytes.formattedFileSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(
            item.historyOutcomeColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
    }
}

private struct FolderSyncRecoveryGroupCard: View {
    let group: FolderSyncRecoveryGroup
    let isBusy: Bool
    let requestRollback: () -> Void

    @State private var showsRecords = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retained run \(group.shortRunID)")
                        .font(.callout.weight(.semibold))
                    Text(
                        "\(group.records.count) recovery record\(group.records.count == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    requestRollback()
                } label: {
                    Label("Roll Back", systemImage: "arrow.uturn.backward")
                }
                .disabled(isBusy)
                .help("Roll back this retained run using its recovery journal")
                .accessibilityHint("Shows a confirmation before rollback")
            }

            DisclosureGroup(isExpanded: $showsRecords) {
                LazyVStack(spacing: 8) {
                    ForEach(group.records) { record in
                        FolderSyncRecoveryRecordRow(record: record)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Recovery Details")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .background(
            Color.teal.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.teal.opacity(0.25))
        }
    }
}

private struct FolderSyncRecoveryRecordRow: View {
    let record: FolderSyncRecoveryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: record.state.symbolName)
                .foregroundStyle(record.state.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(record.action.title)
                        .font(.caption.weight(.semibold))
                    Text(record.state.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(record.state.color)
                }

                Text(record.targetPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let mechanism = record.retentionMechanism {
                    Text(mechanism.historyDescription)
                        .font(.caption2)
                        .foregroundStyle(.teal)
                } else if record.action == .createdItem {
                    Text("Run-created item; rollback removes it only if unchanged.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let failureMessage = record.failureMessage, !failureMessage.isEmpty {
                    Text(failureMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .background(
            record.state.color.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.accessibilitySummary)
    }
}

private struct FolderSyncRecoveryGroup: Identifiable {
    let runID: UUID
    let records: [FolderSyncRecoveryRecord]

    var id: UUID { runID }
    var latestSequence: Int64 { records.map(\.sequence).max() ?? 0 }
    var shortRunID: String { String(runID.uuidString.prefix(8)) }
}

private enum FolderSyncHistoryConfirmation: Identifiable {
    case clearHistory
    case rollback(runID: UUID, title: String, recordCount: Int)

    var id: String {
        switch self {
        case .clearHistory:
            "clear-history"
        case .rollback(let runID, _, _):
            "rollback-\(runID.uuidString)"
        }
    }
}
