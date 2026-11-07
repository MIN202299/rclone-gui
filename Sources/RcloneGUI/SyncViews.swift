import AppKit
import SwiftUI

// MARK: - Status

/// One-line status for a backup task: progress while running, otherwise the last result.
struct SyncStatusLine: View {
    let task: SyncTask
    @Environment(SyncManager.self) private var sync

    var body: some View {
        if sync.preparing.contains(task.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(task.encrypted ? "Checking the encrypted backup…" : "Checking the remote folder…")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let t = sync.running[task.id] {
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
    private func newTask() -> SyncTask { model.backupTaskForCurrentFolder() }
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
                    if task.encrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
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
    @State private var password = ""
    @State private var confirmPassword = ""
    /// Whether the keychain already has this task's password (editing an encrypted task).
    @State private var hasSavedPassword = false

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
                    Toggle("Skip macOS system files", isOn: $task.skipSystemFiles)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Exclude")
                        TextEditor(text: excludesText)
                            .font(.body.monospaced())
                            .frame(height: 64)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background.secondary, in: .rect(cornerRadius: 6))
                            .overlay(alignment: .topLeading) {
                                if task.excludes.isEmpty {
                                    Text(verbatim: "*.tmp\nnode_modules/**")
                                        .font(.body.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                } header: {
                    Text("Filters")
                } footer: {
                    Text("System files are .DS_Store, ._* files and Spotlight or Trash folders. Add one rclone pattern per line: *.tmp skips those files in every folder, node_modules/** skips a whole folder. Excluded files aren't copied; copies already backed up stay as they are.")
                        .formFooter()
                }
                Section {
                    Toggle("Encrypt the remote copy", isOn: $task.encrypted)
                    if task.encrypted {
                        SecureField("Password", text: $password,
                                    prompt: Text(hasSavedPassword ? "Saved in the keychain — leave empty to keep it" : "Required"))
                        SecureField("Confirm password", text: $confirmPassword)
                        Toggle("Also encrypt file and folder names", isOn: $task.encryptNames)
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    if task.encrypted {
                        Text("Files are encrypted on this Mac before they're uploaded (rclone crypt), so the remote only ever stores encrypted data. The password is kept in your keychain. If you forget it, the backup can't be read by anyone — write it down somewhere safe. An encrypted backup needs a new or empty remote folder; any copy of rclone can read it with the same password. Name encryption applies when the backup is first created.")
                            .formFooter()
                    } else {
                        Text("Encrypt files before they leave this Mac, so the remote only stores data no one can read without your password.")
                            .formFooter()
                    }
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
                    task.excludes = task.excludes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let account = CryptKeychain.taskAccount(task.id)
                    if task.encrypted, !password.isEmpty {
                        guard CryptKeychain.setPassword(password, account) else {
                            keychainFailed = true
                            return
                        }
                    } else if !task.encrypted {
                        CryptKeychain.delete(account)
                    }
                    sync.save(task)
                    if isNew { sync.run(task.id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
        .onAppear { hasSavedPassword = CryptKeychain.password(CryptKeychain.taskAccount(task.id)) != nil }
        .alert("Couldn't save the password in the keychain.", isPresented: $keychainFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    @State private var keychainFailed = false

    /// The exclude patterns as editable text, one per line.
    private var excludesText: Binding<String> {
        Binding(get: { task.excludes.joined(separator: "\n") },
                set: { task.excludes = $0.components(separatedBy: "\n") })
    }

    private var problem: String? {
        if task.name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a name.") }
        if task.localPath.isEmpty { return String(localized: "Choose a local folder.") }
        if task.remote.isEmpty { return String(localized: "Choose a remote.") }
        if task.encrypted {
            if password.isEmpty && !hasSavedPassword { return String(localized: "Enter a password for the encrypted backup.") }
            if password != confirmPassword { return String(localized: "The passwords don't match.") }
        }
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
