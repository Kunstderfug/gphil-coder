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
                Picker("Action", selection: $model.mediaRenameOperation) {
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
                Picker("Sort", selection: $model.mediaRenameSort) {
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

            if model.mediaRenameOperation == .pattern || model.mediaRenameOperation == .addText {
                Divider()
                indexControls
            }
        }
    }

    @ViewBuilder
    private var operationControls: some View {
        switch model.mediaRenameOperation {
        case .pattern:
            settingRow("Pattern") {
                TextField("Pattern", text: $model.mediaRenamePattern)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isMediaCopyBusy)
                    .help("Use {name}, {index}, and {parent}")
            }
        case .replaceText:
            VStack(alignment: .leading, spacing: 10) {
                settingRow("Find") {
                    TextField("Find", text: $model.mediaRenameFindText)
                        .textFieldStyle(.roundedBorder)
                }
                settingRow("Replace") {
                    TextField("Replace", text: $model.mediaRenameReplacementText)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Case sensitive", isOn: $model.mediaRenameIsCaseSensitive)
                    .padding(.leading, 104)
            }
            .disabled(model.isMediaCopyBusy)
        case .addText:
            VStack(alignment: .leading, spacing: 10) {
                settingRow("Text") {
                    TextField("Text", text: $model.mediaRenameAddedText)
                        .textFieldStyle(.roundedBorder)
                        .help("Use {name}, {index}, and {parent}")
                }
                settingRow("Position") {
                    Picker("Position", selection: $model.mediaRenameTextPlacement) {
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
                Picker("Case", selection: $model.mediaRenameCaseStyle) {
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
            Stepper(value: $model.mediaRenameStartIndex, in: 0...999_999) {
                valueRow("Start", value: model.mediaRenameStartIndex)
            }

            Stepper(value: $model.mediaRenameIndexStep, in: 1...999) {
                valueRow("Step", value: model.mediaRenameIndexStep)
            }

            Stepper(value: $model.mediaRenameIndexPadding, in: 1...8) {
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
