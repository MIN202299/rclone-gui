import AppKit
import SwiftUI

// MARK: - Status

/// One-line status for a backup task: progress while running, otherwise the last result.
struct SyncStatusLine: View {
    let task: SyncTask
    @Environment(SyncManager.self) private var sync

    var body: some View {
        if let t = sync.running[task.id] {
            HStack(spacing: 6) {
                if let fraction = t.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(t.statusText).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        } else if task.paused {
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if let last = task.lastRun {
            let ok = task.lastSuccess == true
            Label {
                Text(ok ? String(localized: "Backed up \(last.formatted(.relative(presentation: .named))) · \(task.lastMessage ?? "")")
                        : (task.lastMessage ?? String(localized: "Failed")))
                    .lineLimit(2)
                    .help(task.lastMessage ?? "")
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        } else {
            Label("Not backed up yet", systemImage: "clock").foregroundStyle(.secondary)
        }
    }
}

struct SyncTaskIcon: View {
    let task: SyncTask
    @Environment(SyncManager.self) private var sync

    var body: some View {
        Image(systemName: task.mode.symbol)
            .font(.title2)
            .foregroundStyle(task.paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .symbolEffect(.pulse, isActive: sync.isRunning(task.id))
            .frame(width: 30)
    }
}

// MARK: - Backup Tasks window

struct SyncTasksView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var editing: SyncTask?
    @State private var deleting: SyncTask?

    var body: some View {
        Group {
            if sync.tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Backup Tasks", systemImage: "externaldrive.badge.timemachine")
                } description: {
                    Text("A backup task copies new and changed files between a local folder and a remote folder — once, on a schedule, or whenever local files change. It never deletes anything.")
                } actions: {
                    Button("New Backup Task…") { editing = newTask() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(sync.tasks) { task in
                        SyncTaskRow(task: task, edit: { editing = task }, delete: { deleting = task })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 620, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = newTask() } label: { Label("New Backup Task", systemImage: "plus") }
                    .help("New Backup Task")
            }
        }
        .navigationTitle("Backup Tasks")
        .sheet(item: $editing) { task in
            SyncTaskEditor(task: task, isNew: sync.task(task.id) == nil)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { task in
            Button("Delete Task", role: .destructive) { sync.delete(task.id) }
        } message: { _ in
            Text("Only the backup task is removed. Files in both folders stay as they are.")
        }
    }

    /// A new task prefilled from the folder open in the browser.
    private func newTask() -> SyncTask {
        let remote = model.selectedRemoteName ?? model.remotes.first?.name ?? ""
        let path = model.selectedRemoteName == nil ? "" : model.path
        let name = path.split(separator: "/").last.map(String.init) ?? remote
        return SyncTask(name: name, localPath: "", remote: remote, remotePath: path, mode: .upload)
    }
}

private struct SyncTaskRow: View {
    let task: SyncTask
    let edit: () -> Void
    let delete: () -> Void
    @Environment(SyncManager.self) private var sync
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SyncTaskIcon(task: task)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name).font(.headline)
                    Text(task.mode.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text("\(SyncManager.displayPath(task.localPath))  \(task.mode.arrow)  \(task.remoteTarget)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Text(task.scheduleText).foregroundStyle(.secondary)
                }
                .font(.caption)
                SyncStatusLine(task: task).font(.caption)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if sync.isRunning(task.id) {
                    Button("Stop") { sync.cancel(task.id) }
                } else {
                    Button("Back Up Now") { sync.run(task.id) }
                        .disabled(task.paused)
                }
                Menu {
                    Button("Edit…", action: edit)
                    Button(task.paused ? "Resume Automatic Backups" : "Pause Automatic Backups") {
                        sync.setPaused(task.id, !task.paused)
                    }
                    Divider()
                    Button("Show Local Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([task.localURL])
                    }
                    Button("Open Remote Folder") {
                        model.selectedRemoteName = task.remote
                        model.navigate(to: task.remotePath)
                        MainWindow.show()
                    }
                    Divider()
                    Button("Delete Task…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Back Up Now") { sync.run(task.id) }.disabled(sync.isRunning(task.id) || task.paused)
            Button("Edit…", action: edit)
            Button("Delete Task…", role: .destructive, action: delete)
        }
    }
}

// MARK: - Editor

struct SyncTaskEditor: View {
    @State var task: SyncTask
    let isNew: Bool
    @Environment(SyncManager.self) private var sync
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $task.name)
                }
                Section("Folders") {
                    LabeledContent("Local folder") {
                        HStack {
                            Text(task.localPath.isEmpty ? String(localized: "None") : SyncManager.displayPath(task.localPath))
                                .foregroundStyle(task.localPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseLocal() }
                        }
                    }
                    Picker("Remote", selection: $task.remote) {
                        ForEach(model.remotes) { Text($0.name).tag($0.name) }
                    }
                    TextField("Remote folder", text: $task.remotePath, prompt: Text("Path inside the remote, e.g. Photos/2026"))
                }
                Section {
                    Picker("Direction", selection: $task.mode) {
                        ForEach(SyncTask.Mode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(task.mode.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Direction")
                }
                Section {
                    Picker("Back up automatically", selection: $task.intervalMinutes) {
                        ForEach(SyncTask.intervalChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    Toggle("Also back up when local files change", isOn: $task.watchLocal)
                        .disabled(task.mode == .download)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Automatic backups run while Rclone is open, including when only its menu bar icon is showing.")
                        .formFooter()
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create and Back Up Now" : "Save") {
                    task.name = task.name.trimmingCharacters(in: .whitespaces)
                    task.remotePath = task.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    sync.save(task)
                    if isNew { sync.run(task.id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 540)
    }

    private var problem: String? {
        if task.name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a name.") }
        if task.localPath.isEmpty { return String(localized: "Choose a local folder.") }
        if task.remote.isEmpty { return String(localized: "Choose a remote.") }
        return nil
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the local folder for this backup")
        if !task.localPath.isEmpty { panel.directoryURL = task.localURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        task.localPath = url.path
        if task.name.isEmpty { task.name = url.lastPathComponent }
    }
}

// MARK: - Browser banner

/// Shown above the file list when the open folder belongs to a backup task.
struct SyncBanner: View {
    let task: SyncTask
    @Environment(SyncManager.self) private var sync
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.mode.symbol).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: sync.isRunning(task.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(task.mode == .upload
                     ? String(localized: "Backed up from \(SyncManager.displayPath(task.localPath))")
                     : String(localized: "Backed up to \(SyncManager.displayPath(task.localPath))"))
                    .lineLimit(1).truncationMode(.middle)
                SyncStatusLine(task: task).font(.caption)
            }
            Spacer()
            if sync.isRunning(task.id) {
                Button("Stop") { sync.cancel(task.id) }
            } else {
                Button("Back Up Now") { sync.run(task.id) }.disabled(task.paused)
            }
            Button("Manage…") { openWindow(id: "sync") }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.tint.opacity(0.08))
    }
}
