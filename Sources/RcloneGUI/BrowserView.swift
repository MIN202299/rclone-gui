import AppKit
import QuickLook
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\Entry.name, comparator: .localizedStandard)]
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: Entry?
    @State private var renameText = ""
    @State private var pendingDelete: [Entry] = []
    @State private var showingTransfers = false
    @State private var isDropTargeted = false
    @State private var newSyncTask: SyncTask?
    @Environment(SyncManager.self) private var sync
    @Environment(\.openWindow) private var openWindow

    private var rows: [Entry] {
        let sorted = model.visibleEntries.sorted(using: sortOrder)
        // Keep folders grouped above files, like Finder.
        return sorted.filter(\.isDir) + sorted.filter { !$0.isDir }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PathBar()
            Divider()
            ForEach(sync.tasks(forRemoteTarget: model.target())) { task in
                SyncBanner(task: task)
                Divider()
            }
            table
            Divider()
            StatusBar(showingTransfers: $showingTransfers)
        }
        .navigationTitle(model.selectedRemoteName ?? "")
        .navigationSubtitle(model.path.isEmpty ? "/" : model.path)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter this folder")
        .toolbar { toolbar }
        .quickLookPreview($model.quickLookURL)
        .onChange(of: model.selection) {
            // Like Finder: while Quick Look is open, it follows the selection.
            if model.isQuickLookVisible, model.selectedEntries.count == 1, !model.selectedEntries[0].isDir {
                model.quickLook(model.selectedEntries[0])
            }
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await model.makeFolder(named: newFolderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { entry in
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await model.rename(entry, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete
                Task { await model.delete(items) }
            }
        } message: {
            Text("This permanently deletes the items from the remote. Folders are deleted with all their contents. This can't be undone.")
        }
        .sheet(item: $newSyncTask) { task in
            SyncTaskEditor(task: task, isNew: true)
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? String(localized: "Delete “\(pendingDelete[0].name)”?")
            : String(localized: "Delete \(pendingDelete.count) items?")
    }

    // MARK: Table

    private var table: some View {
        @Bindable var model = model
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 6) {
                    Label {
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                    }
                    Spacer(minLength: 4)
                    RowStatus(transfer: model.activeTransfer(for: entry),
                              cached: model.cachedIDs.contains(entry.id))
                }
            }
            .width(min: 200, ideal: 360)
            TableColumn("Size", value: \.sortSize) { entry in
                Group {
                    if entry.size < 0, !entry.isDir, let exported = model.cachedSizes[entry.id] {
                        Text(exported.byteString)
                            .help("Size of the exported copy cached on this Mac. Google Docs, Sheets and Slides have no fixed size on Drive.")
                    } else {
                        Text(entry.sizeText)
                            .help(entry.isDir || entry.size >= 0 ? "" : "Size unknown until opened — Google Docs, Sheets and Slides have no fixed size on Drive")
                    }
                }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 140)
            TableColumn("Modified", value: \.modTime) { entry in
                Text(entry.modTime == .distantPast ? "--" : entry.modTime.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 220)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            contextMenu(for: model.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }) {
                model.open(entry)
            }
        }
        .overlay { overlay }
        .overlay(alignment: .bottom) {
            if let loading = model.loading {
                LoadingToast(transfer: loading, message: model.loadingMessage) { model.cancelLoading() }
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.loading?.id)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Upload to \(model.path.isEmpty ? model.selectedRemoteName ?? "" : model.pathComponents.last ?? "")",
                              systemImage: "arrow.up.doc")
                            .font(.title3.weight(.medium))
                            .padding(12)
                            .background(.regularMaterial, in: .capsule)
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.upload(files)
            showingTransfers = true
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onKeyPress(.space) {
            guard model.isQuickLookVisible || model.selectedEntries.count == 1 else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard model.selectedEntries.count == 1 else { return .ignored }
            model.open(model.selectedEntries[0])
            return .handled
        }
        .onDeleteCommand {
            if !model.selectedEntries.isEmpty { pendingDelete = model.selectedEntries }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = model.listError {
            ContentUnavailableView {
                Label("Couldn't Load Folder", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView()
        } else if !model.isLoading && model.entries.isEmpty {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("Drop files here or click Upload to add some.")
            }
        } else if !model.searchText.isEmpty && model.visibleEntries.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    @ViewBuilder
    private func contextMenu(for items: [Entry]) -> some View {
        if items.count == 1, let entry = items.first {
            Button(entry.isDir ? "Open" : "Open with Default App") { model.open(entry) }
            if !entry.isDir {
                Button("Quick Look") { model.quickLook(entry) }
            }
            Divider()
        }
        if !items.isEmpty {
            Button("Download…") { chooseDownloadFolder(for: items) }
            if items.count == 1, let entry = items.first {
                Button("Rename…") {
                    renameText = entry.name
                    renaming = entry
                }
            }
            Button("Copy Path") { model.copyPath(items) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = items }
        } else {
            Button("New Folder…") { newFolderName = ""; showingNewFolder = true }
            Button("Upload…") { chooseUploads() }
            Button("Refresh") { Task { await model.reload() } }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.backStack.isEmpty)
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(model.forwardStack.isEmpty)
                .help("Forward")
        }
        // One visual language: plain outline SF Symbols at the same weight, no circles or menu
        // chevrons, grouped by purpose (create/move files · sync · destructive · view).
        ToolbarItemGroup(placement: .primaryAction) {
            Button { newFolderName = ""; showingNewFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder")
            Button { chooseUploads() } label: { Label("Upload", systemImage: "icloud.and.arrow.up") }
                .help("Upload files or folders here")
            Button { chooseDownloadFolder(for: model.selectedEntries) } label: {
                Label("Download", systemImage: "icloud.and.arrow.down")
            }
            .disabled(model.selection.isEmpty)
            .help("Download selected items")
            Menu {
                Button("New Sync Task for This Folder…") {
                    let name = model.pathComponents.last ?? model.selectedRemoteName ?? ""
                    newSyncTask = SyncTask(name: name, localPath: "", remote: model.selectedRemoteName ?? "",
                                           remotePath: model.path, mode: .upload)
                }
                let here = sync.tasks(forRemoteTarget: model.target())
                if !here.isEmpty {
                    Divider()
                    ForEach(here) { task in
                        Button("Sync “\(task.name)” Now") { sync.run(task.id) }
                            .disabled(sync.isRunning(task.id) || task.paused)
                    }
                }
                Divider()
                Button("Sync Tasks…") { openWindow(id: "sync") }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .menuIndicator(.hidden)
            .help("Keep this folder in sync with a local folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { pendingDelete = model.selectedEntries } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
                .help("Delete selected items")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
            Button { showingTransfers.toggle() } label: {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
            }
            .foregroundStyle(model.activeTransfers.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .help(model.activeTransfers.isEmpty ? "Transfers" : "Transfers (\(model.activeTransfers.count) running)")
            .popover(isPresented: $showingTransfers, arrowEdge: .bottom) {
                TransfersView()
            }
        }
    }

    // MARK: Panels

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.message = String(localized: "Choose files or folders to upload to \(model.target())")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.upload(panel.urls)
        showingTransfers = true
    }

    private func chooseDownloadFolder(for items: [Entry]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download Here")
        panel.message = items.count == 1 ? String(localized: "Choose where to save “\(items[0].name)”") : String(localized: "Choose where to save \(items.count) items")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.download(items, to: url)
        showingTransfers = true
    }
}

// MARK: - Row status

/// Trailing badge in the Name column: download progress while a transfer reads this item,
/// otherwise a check when an up-to-date copy is cached on this Mac.
private struct RowStatus: View {
    let transfer: Transfer?
    let cached: Bool

    var body: some View {
        if let transfer {
            HStack(spacing: 4) {
                if let fraction = transfer.fraction {
                    ProgressRing(fraction: fraction)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .help(transfer.statusText)
        } else if cached {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help("Cached on this Mac — opens instantly")
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
        }
        .frame(width: 11, height: 11)
    }
}

// MARK: - Loading toast

/// Floating "Loading preview…" bar shown while a file is fetched for opening or Quick Look.
private struct LoadingToast: View {
    let transfer: Transfer
    let message: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                    .lineLimit(1).truncationMode(.middle)
                Text(transfer.statusText)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: - Path bar

private struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb(model.selectedRemote?.name ?? "", symbol: model.selectedRemote?.symbol, path: "")
                ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    crumb(name, symbol: nil, path: model.pathComponents.prefix(index + 1).joined(separator: "/"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private func crumb(_ title: String, symbol: String?, path: String) -> some View {
        Button { model.navigate(to: path) } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fontWeight(path == model.path ? .semibold : .regular)
        .foregroundStyle(path == model.path ? .primary : .secondary)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showingTransfers: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(summary).foregroundStyle(.secondary)
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            let active = model.activeTransfers
            if !active.isEmpty {
                Button { showingTransfers = true } label: {
                    HStack(spacing: 6) {
                        Text(active.count == 1 ? "1 transfer" : "\(active.count) transfers")
                        if let p = model.overallProgress {
                            ProgressView(value: p).frame(width: 90)
                            Text(p.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var summary: String {
        let entries = model.visibleEntries
        let folders = entries.filter(\.isDir).count
        let files = entries.count - folders
        let bytes = entries.filter { !$0.isDir && $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? String(localized: "1 folder") : String(localized: "\(folders) folders")) }
        if files > 0 { parts.append(files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")) }
        if parts.isEmpty { return model.isLoading ? String(localized: "Loading…") : String(localized: "No items") }
        var text = parts.joined(separator: String(localized: ", ", comment: "Separates “3 folders” and “5 files” in the status bar"))
        if bytes > 0 { text += " · \(bytes.byteString)" }
        if !model.selection.isEmpty { text = String(localized: "\(model.selection.count) selected of \(text)") }
        return text
    }
}
