import AppKit
import GPhilCoderCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: EncoderViewModel
    @State private var selectedWorkflowTab: WorkflowTab = .audioEncoding
    @State private var selectedMediaCopyPreviewMode: MediaCopyPreviewMode = .plan
    @State private var showingInputFilterSheet = false
    @State private var isEncodingDropTargeted = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titlebarSpacer
                AppTopBar(selectedWorkflowTab: $selectedWorkflowTab)
                Divider()
                workflowContentContainer
                Divider()
                AppFooter()
            }
        }
        .accentColor(.teal)
        .sheet(isPresented: $showingInputFilterSheet) {
            InputFilterSheet()
                .environmentObject(model)
        }
        .onAppear {
            syncWorkflowSelection(selectedWorkflowTab)
        }
        .onChange(of: selectedWorkflowTab) { _, tab in
            syncWorkflowSelection(tab)
        }
    }

    @ViewBuilder
    private var selectedWorkflowContent: some View {
        switch selectedWorkflowTab {
        case .audioEncoding, .videoEncoding:
            EncodingWorkflowView(
                showingInputFilterSheet: $showingInputFilterSheet,
                isEncodingDropTargeted: $isEncodingDropTargeted
            )
        case .mediaCopy:
            mediaManagementWorkflow(for: .copy)
        case .mediaRename:
            mediaManagementWorkflow(for: .rename)
        case .mediaDelete:
            mediaManagementWorkflow(for: .delete)
        case .folderSync:
            FolderSyncWorkflowView()
        case .backupRestore:
            RestoreFromBackupSheet(isEmbedded: true)
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workflowContentContainer: some View {
        GeometryReader { proxy in
            selectedWorkflowContent
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var titlebarSpacer: some View {
        Color.clear
            .frame(height: 10)
            .background(.bar)
    }

    private func mediaManagementWorkflow(for mode: FileManagementMode) -> some View {
        MediaManagementWorkflowView(
            mode: mode,
            selectedMediaCopyPreviewMode: $selectedMediaCopyPreviewMode
        )
    }

    private func syncWorkflowSelection(_ tab: WorkflowTab) {
        switch tab {
        case .audioEncoding:
            model.encodingWorkflow = .audio
        case .videoEncoding:
            model.encodingWorkflow = .video
        case .backupRestore:
            break
        case .folderSync:
            break
        case .mediaCopy:
            model.fileManagementMode = .copy
            selectedMediaCopyPreviewMode = .plan
        case .mediaRename:
            model.fileManagementMode = .rename
        case .mediaDelete:
            model.fileManagementMode = .delete
        }
    }
}
