import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var remoteToDelete: Remote?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRemoteName) {
            Section("Remotes") {
                ForEach(model.remotes) { remote in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(remote.name)
                            Text(remote.type).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: remote.symbol)
                    }
                    .tag(remote.name)
                    .contextMenu {
                        Button("Refresh") { Task { await model.reload(); await model.loadAbout() } }
                        Divider()
                        Button("Remove Remote…", role: .destructive) { remoteToDelete = remote }
                    }
                }
            }
            if let error = model.remotesError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let about = model.about, let used = about.used {
                    UsageView(about: about, used: used)
                }
                HStack {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .help("Add Remote")
                    Button { if let r = model.selectedRemote { remoteToDelete = r } } label: { Image(systemName: "minus") }
                        .help("Remove Remote")
                        .disabled(model.selectedRemote == nil)
                    Spacer()
                    Button { Task { await model.loadRemotes() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload Remotes")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .sheet(isPresented: $showingAdd) {
            AddRemoteView()
        }
        .confirmationDialog(
            "Remove “\(remoteToDelete?.name ?? "")”?",
            isPresented: Binding(get: { remoteToDelete != nil }, set: { if !$0 { remoteToDelete = nil } }),
            presenting: remoteToDelete
        ) { remote in
            Button("Remove Remote", role: .destructive) {
                Task { await model.deleteRemote(remote.name) }
            }
        } message: { _ in
            Text("This removes the remote from your rclone configuration. Files stored in the cloud are not touched.")
        }
    }
}

private struct UsageView: View {
    let about: About
    let used: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let total = about.total, total > 0 {
                ProgressView(value: Double(used), total: Double(total))
                    .tint(Double(used) / Double(total) > 0.9 ? .red : .accentColor)
                Text("\(used.byteString) of \(total.byteString) used")
            } else {
                Text("\(used.byteString) used")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
