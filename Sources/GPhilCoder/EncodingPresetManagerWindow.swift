import GPhilCoderCore
import SwiftUI

struct EncodingPresetManagerWindow: View {
    @EnvironmentObject private var model: EncoderViewModel
    @State private var selectedWorkflow: EncodingWorkflow = .audio
    @State private var selectedPresetID: UUID?

    private var presets: [EncodingPreset] {
        model.encodingPresets
            .filter { $0.workflow == selectedWorkflow }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedPreset: EncodingPreset? {
        guard let selectedPresetID else { return nil }
        return model.encodingPresets.first { $0.id == selectedPresetID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                presetList
                    .frame(width: 240)

                Divider()

                detailPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            selectedWorkflow = model.encodingWorkflow
            selectedPresetID = selectedPresetID(for: selectedWorkflow)
        }
        .onChange(of: selectedWorkflow) { _, workflow in
            selectedPresetID = selectedPresetID(for: workflow)
        }
        .onChange(of: model.encodingPresets) { _, presets in
            guard let selectedPresetID,
                presets.contains(where: { $0.id == selectedPresetID })
            else {
                self.selectedPresetID = self.presets.first?.id
                return
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Workflow", selection: $selectedWorkflow) {
                ForEach(EncodingWorkflow.allCases) { workflow in
                    Label(workflow.title, systemImage: workflow.symbolName)
                        .tag(workflow)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()

            Button {
                model.saveCurrentSettingsAsEncodingPreset()
                selectedWorkflow = model.encodingWorkflow
                selectedPresetID = model.selectedEncodingPresetID
            } label: {
                Label("Save Current", systemImage: "plus.circle")
            }
            .disabled(model.isEncoding)
        }
        .padding(16)
        .background(.bar)
    }

    private var presetList: some View {
        VStack(spacing: 0) {
            if presets.isEmpty {
                ContentUnavailableView(
                    "No Presets",
                    systemImage: selectedWorkflow.symbolName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPresetID) {
                    ForEach(presets) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(preset.name)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                if isActivePreset(preset) {
                                    Text("Active")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.teal)
                                        .help("This preset is loaded into the current workflow.")
                                }
                            }
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .tag(Optional(preset.id))
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selectedPreset {
                HStack(spacing: 10) {
                    Image(systemName: selectedPreset.workflow.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selectedPreset.workflow == .video ? .indigo : .teal)
                        .frame(width: 38, height: 38)
                        .background(
                            (selectedPreset.workflow == .video ? Color.indigo : Color.teal)
                                .opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedPreset.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(selectedPreset.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    DetailLine(title: "Workflow", value: selectedPreset.workflow.title)
                    DetailLine(title: "Updated", value: selectedPreset.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    DetailLine(title: "Created", value: selectedPreset.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        model.loadEncodingPreset(selectedPreset)
                        selectedWorkflow = selectedPreset.workflow
                        selectedPresetID = selectedPreset.id
                    } label: {
                        Label("Load", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isEncoding)

                    Button {
                        model.updateEncodingPreset(selectedPreset)
                    } label: {
                        Label("Update", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isEncoding || selectedPreset.workflow != model.encodingWorkflow)
                }

                HStack(spacing: 8) {
                    Button {
                        model.renameEncodingPreset(selectedPreset)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isEncoding)

                    Button(role: .destructive) {
                        model.deleteEncodingPreset(selectedPreset)
                        selectedPresetID = presets.first?.id
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isEncoding)
                }
            } else {
                ContentUnavailableView(
                    "No Preset Selected",
                    systemImage: "slider.horizontal.3"
                )
                Spacer()
            }
        }
        .padding(18)
    }

    private func selectedPresetID(for workflow: EncodingWorkflow) -> UUID? {
        switch workflow {
        case .audio:
            return model.selectedAudioEncodingPresetID
        case .video:
            return model.selectedVideoEncodingPresetID
        }
    }

    private func isActivePreset(_ preset: EncodingPreset) -> Bool {
        selectedPresetID(for: preset.workflow) == preset.id
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.callout)
    }
}
