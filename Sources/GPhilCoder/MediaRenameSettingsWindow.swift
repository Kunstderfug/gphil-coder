import GPhilCoderCore
import SwiftUI

struct MediaRenameSettingsWindow: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        VStack(spacing: 0) {
            MediaRenameSettingsForm()
                .padding(20)

            Divider()

            HStack(spacing: 10) {
                FormatPill(text: model.mediaRenameOperation.title.uppercased())
                FormatPill(text: model.mediaRenameSort.title.uppercased())

                Spacer()

                Button {
                    model.refreshMediaRenamePreview()
                } label: {
                    Label("Refresh Preview", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canRefreshMediaRenamePreview)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MediaRenameSettingsForm: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow("Action") {
                Picker("Action", selection: model.binding(\.mediaRenameOperation)) {
                    ForEach(MediaRenameOperation.allCases) { operation in
                        Text(operation.title)
                            .tag(operation)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isMediaCopyBusy)
                .arrowCursorOnHover()
            }

            operationControls

            Divider()

            settingRow("Sort") {
                Picker("Sort", selection: model.binding(\.mediaRenameSort)) {
                    ForEach(MediaRenameSort.allCases) { sort in
                        Text(sort.title)
                            .tag(sort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isMediaCopyBusy)
                .arrowCursorOnHover()
            }

            if model.mediaRenameOperation.usesIndexControls {
                Divider()
                indexControls
            }
        }
    }

    @ViewBuilder
    private var operationControls: some View {
        switch model.mediaRenameOperation {
        case .pattern:
            VStack(alignment: .leading, spacing: 8) {
                settingRow("Pattern") {
                    TextField("Pattern", text: model.binding(\.mediaRenamePattern))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isMediaCopyBusy)
                        .help("Use {name}, {index}, {parent}, and {date}")
                }

                PatternVariableHelp()
                    .padding(.leading, 104)
            }
        case .autoIndex:
            settingRow("Name") {
                Text("Use the increasing index as the file name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .replaceText:
            VStack(alignment: .leading, spacing: 10) {
                settingRow("Find") {
                    TextField("Find", text: model.binding(\.mediaRenameFindText))
                        .textFieldStyle(.roundedBorder)
                }
                settingRow("Replace") {
                    TextField("Replace", text: model.binding(\.mediaRenameReplacementText))
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Case sensitive", isOn: model.binding(\.mediaRenameIsCaseSensitive))
                    .padding(.leading, 104)
            }
            .disabled(model.isMediaCopyBusy)
        case .addText:
            VStack(alignment: .leading, spacing: 10) {
                settingRow("Text") {
                    TextField("Text", text: model.binding(\.mediaRenameAddedText))
                        .textFieldStyle(.roundedBorder)
                        .help("Use {name}, {index}, {parent}, and {date}")
                }
                settingRow("Position") {
                    Picker("Position", selection: model.binding(\.mediaRenameTextPlacement)) {
                        ForEach(MediaRenameTextPlacement.allCases) { placement in
                            Text(placement.title)
                                .tag(placement)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .arrowCursorOnHover()
                }
            }
            .disabled(model.isMediaCopyBusy)
        case .changeCase:
            settingRow("Case") {
                Picker("Case", selection: model.binding(\.mediaRenameCaseStyle)) {
                    ForEach(MediaRenameCaseStyle.allCases) { style in
                        Text(style.title)
                            .tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(model.isMediaCopyBusy)
                .arrowCursorOnHover()
            }
        case .cleanUp:
            EmptyView()
        }
    }

    private var indexControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: model.binding(\.mediaRenameStartIndex), in: 0...999_999) {
                valueRow("Start", value: model.mediaRenameStartIndex)
            }

            Stepper(value: model.binding(\.mediaRenameIndexStep), in: 1...999) {
                valueRow("Step", value: model.mediaRenameIndexStep)
            }

            Stepper(value: model.binding(\.mediaRenameIndexPadding), in: 1...8) {
                valueRow("Digits", value: model.mediaRenameIndexPadding)
            }
        }
        .disabled(model.isMediaCopyBusy)
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func valueRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

private struct PatternVariableHelp: View {
    private let variables: [(token: String, detail: String)] = [
        ("{name}", "Original file name without extension"),
        ("{index}", "Increasing number using Start, Step, and Digits"),
        ("{parent}", "Containing folder name"),
        ("{date}", "Modified date as yyyy-MM-dd")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Available variables")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(variables, id: \.token) { variable in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(variable.token)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 58, alignment: .leading)

                        Text(variable.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private extension MediaRenameOperation {
    var usesIndexControls: Bool {
        switch self {
        case .pattern, .autoIndex, .addText:
            true
        case .replaceText, .changeCase, .cleanUp:
            false
        }
    }
}
