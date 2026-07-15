import AppKit
import GPhilCoderCore
import SwiftUI

enum WorkflowTab: CaseIterable, Hashable, Identifiable {
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

    var iconColor: Color {
        switch self {
        case .audioEncoding:
            .teal
        case .videoEncoding:
            .purple
        case .mediaCopy:
            .blue
        case .mediaRename:
            .orange
        case .mediaDelete:
            .red
        case .folderSync:
            .green
        case .backupRestore:
            .indigo
        }
    }
}

enum MediaCopyPreviewMode: Hashable {
    case plan
    case queue
}

struct AppTopBar: View {
    @Binding var selectedWorkflowTab: WorkflowTab

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                HeaderAppIcon()

                VStack(alignment: .leading, spacing: 2) {
                    Text("GPhil MediaFlow")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Batch audio/video encoding and filtered media workflows")
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
}

struct AppFooter: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
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

struct StatLine: View {
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

struct FolderPickerControl: View {
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

struct CenteredStatusView: View {
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

struct SettingValue: View {
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
                    .foregroundStyle(tab.iconColor)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 10)
            .foregroundStyle(isSelected ? tab.iconColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? tab.iconColor.opacity(0.14) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? tab.iconColor.opacity(0.35) : Color.clear)
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
