import AppKit
import SwiftUI

@main
struct RcloneGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var sync = SyncManager.shared

    var body: some Scene {
        WindowGroup("Rclone", id: "main") {
            ContentView()
                .environment(model)
                .environment(sync)
                .frame(minWidth: 820, minHeight: 480)
                .task {
                    sync.onTransferStarted = { [model] in model.adoptTransfer($0) }
                    sync.onTaskFinished = { [model] task in
                        // Refresh the open folder if this sync changed it.
                        if model.target() == task.remoteTarget { Task { await model.reload() } }
                    }
                    await model.loadRemotes()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.selectedRemoteName == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(model.backStack.isEmpty)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(model.forwardStack.isEmpty)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                    .disabled(model.path.isEmpty)
                Divider()
                Button("Sync Tasks") { MainWindow.openSync?() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Quick Look") { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(!model.isQuickLookVisible && (model.selectedEntries.count != 1 || model.selectedEntries.first?.isDir == true))
            }
        }

        Window("Sync Tasks", id: "sync") {
            SyncTasksView()
                .environment(model)
                .environment(sync)
        }
        .defaultSize(width: 760, height: 600)

        MenuBarExtra {
            MenuBarView().environment(model).environment(sync)
        } label: {
            MenuBarLabel().environment(model).environment(sync)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// SwiftPM executables launch as background processes; promote to a regular app with a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { RcloneDaemon.shared.stop() }
    }

    // Keep running in the menu bar so transfers continue after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The menu bar extra counts as a "visible window", so SwiftUI won't reopen the main
    // window on a Dock click by itself — do it explicitly.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }
}

/// Shows the main window: brings an existing one forward, or creates a new one.
@MainActor
enum MainWindow {
    /// Set by a view that lives for the app's lifetime (the menu bar label).
    static var open: (() -> Void)?
    static var openSync: (() -> Void)?

    static func show() {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        if let window = windows.first(where: { $0.isVisible || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Rclone.pathDefaultsKey) private var rclonePath = ""
    @AppStorage(FileCache.limitKey) private var cacheLimit = Int(FileCache.defaultLimit)
    @State private var cacheUsage: Int64?
    @State private var confirmClear = false
    @State private var pendingLocation: PendingLocation?
    @State private var relocating = false
    @State private var locationError: String?
    @State private var locationTick = 0 // forces the location row to re-read FileCache.root

    private struct PendingLocation: Identifiable {
        let id = UUID()
        let parent: URL? // nil = default location
    }

    var body: some View {
        Form {
            Section {
                TextField("rclone executable", text: $rclonePath, prompt: Text(Rclone.locate() ?? "/opt/homebrew/bin/rclone"))
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.showsHiddenFiles = true
                        if panel.runModal() == .OK, let url = panel.url { rclonePath = url.path }
                    }
                    Button("Use Default") { rclonePath = "" }
                    Spacer()
                    if let found = Rclone.locate() {
                        Label(found, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("rclone")
            } footer: {
                Text("Leave empty to search Homebrew and common install locations.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Maximum cache size", selection: $cacheLimit) {
                    ForEach(FileCache.limitChoices, id: \.self) { Text(Int64($0).byteString).tag(Int($0)) }
                }
                LabeledContent("Currently used") {
                    if let cacheUsage {
                        let fraction = min(1, Double(cacheUsage) / Double(max(cacheLimit, 1)))
                        HStack(spacing: 8) {
                            ProgressView(value: fraction).frame(width: 120)
                            Text(cacheUsage == 0 ? "Empty" : "\(cacheUsage.byteString) of \(Int64(cacheLimit).byteString)").monospacedDigit()
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Location") {
                    let _ = locationTick
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.displayPath(FileCache.root))
                            .lineLimit(1).truncationMode(.middle)
                            .help(FileCache.root.path)
                        if FileCache.isUsingFallback, let chosen = FileCache.chosenParent {
                            Text("“\(Self.displayPath(chosen))” isn't available, so the default location is used for now.")
                                .font(.caption).foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                        if let locationError {
                            Text(locationError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                HStack {
                    Button("Change…") { chooseLocation() }
                    Button("Use Default") { requestLocation(nil) }
                        .disabled(FileCache.chosenParent == nil)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: FileCache.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([FileCache.root])
                    }
                    Spacer()
                    if relocating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Clear Cache…", role: .destructive) { confirmClear = true }
                            .disabled(cacheUsage == 0)
                    }
                }
                .disabled(relocating)
            } header: {
                Text("File Cache")
            } footer: {
                Text("Files you open are kept here, so opening them again is instant unless they changed on the remote. When the cache is full, the least recently opened files are removed. A custom location gets its own “\(FileCache.folderName)” folder. Edits to cached copies are not uploaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onChange(of: rclonePath) { Task { await model.loadRemotes() } }
        .onChange(of: cacheLimit) {
            Task {
                await Task.detached(priority: .utility) { FileCache.enforceLimit() }.value
                await refreshUsage()
                model.refreshCacheStatus()
            }
        }
        .task { await refreshUsage() }
        .confirmationDialog("Move cached files to the new location?",
                            isPresented: Binding(get: { pendingLocation != nil }, set: { if !$0 { pendingLocation = nil } }),
                            presenting: pendingLocation) { pending in
            Button("Move Files") { relocate(pending.parent, moveFiles: true) }
            Button("Start Empty", role: .destructive) { relocate(pending.parent, moveFiles: false) }
        } message: { _ in
            Text("Moving keeps files you've already opened available instantly. Starting empty deletes the current cache (your files on the remotes are not affected).")
        }
        .confirmationDialog("Clear the file cache?", isPresented: $confirmClear) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await Task.detached(priority: .utility) { FileCache.clear() }.value
                    await refreshUsage()
                    model.refreshCacheStatus()
                }
            }
        } message: {
            Text("Cached copies of opened files will be deleted. Your files on the remotes are not affected.")
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where to keep cached files. A “\(FileCache.folderName)” folder will be created inside it."
        panel.directoryURL = FileCache.chosenParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestLocation(url)
    }

    /// Asks whether to move existing files, unless the cache is empty.
    private func requestLocation(_ parent: URL?) {
        locationError = nil
        if (cacheUsage ?? 0) == 0 {
            relocate(parent, moveFiles: false)
        } else {
            pendingLocation = PendingLocation(parent: parent)
        }
    }

    private func relocate(_ parent: URL?, moveFiles: Bool) {
        relocating = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileCache.relocate(to: parent, moveFiles: moveFiles)
                }.value
            } catch {
                locationError = error.localizedDescription
            }
            relocating = false
            locationTick += 1
            await refreshUsage()
            model.refreshCacheStatus()
        }
    }

    private func refreshUsage() async {
        cacheUsage = await Task.detached(priority: .utility) { FileCache.usage() }.value
    }
}
