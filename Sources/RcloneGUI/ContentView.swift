import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            if model.rcloneMissing {
                RcloneSetupView()
            } else if model.selectedRemoteName == nil {
                ContentUnavailableView {
                    Label("No Remote Selected", systemImage: "cloud")
                } description: {
                    Text(model.remotes.isEmpty
                         ? "Add a cloud storage remote to get started."
                         : "Choose a remote from the sidebar.")
                }
            } else {
                BrowserView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

extension View {
    /// Footer text under a grouped form section: secondary and left-aligned. (Grouped forms
    /// otherwise right-align footers, which reads badly once the text wraps.)
    func formFooter() -> some View {
        foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
