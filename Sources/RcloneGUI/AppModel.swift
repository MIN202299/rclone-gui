import AppKit
import Quartz
import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    // Remotes
    var remotes: [Remote] = []
    var selectedRemoteName: String? {
        didSet {
            guard selectedRemoteName != oldValue else { return }
            backStack.removeAll(); forwardStack.removeAll()
            path = ""
            selection.removeAll()
            entries = []
            entriesTarget = nil
            listError = nil
            searchText = ""
            Task { await reload(); await loadAbout() }
            Task { await checkModTimeSupport() }
        }
    }
    var remotesError: String?
    var rcloneMissing = false

    // Browser
    var path = ""
    var entries: [Entry] = []
    var selection = Set<Entry.ID>()
    var isLoading = false
    var listError: String?
    /// Which folder `entries` currently shows (a full rclone target).
    private var entriesTarget: String?
    /// Folder listings seen this session, shown instantly on revisit while a fresh listing loads.
    @ObservationIgnored private var listCache: [String: [Entry]] = [:]
    var searchText = ""
    var backStack: [String] = []
    var forwardStack: [String] = []

    // Usage
    var about: About?

    // Transfers
    var transfers: [Transfer] = []

    // Banner for one-off operation failures (delete, rename…)
    var alertMessage: String?

    var selectedRemote: Remote? { remotes.first { $0.name == selectedRemoteName } }
    var activeTransfers: [Transfer] { transfers.filter(\.isRunning) }

    var overallProgress: Double? {
        let running = activeTransfers.filter { $0.totalBytes > 0 }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return nil }
        return Double(running.reduce(Int64(0)) { $0 + $1.bytes }) / Double(total)
    }

    var overallBytesText: String {
        let running = activeTransfers.filter { $0.totalBytes > 0 }
        let done = running.reduce(Int64(0)) { $0 + $1.bytes }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        return String(localized: "\(done.byteString) of \(total.byteString)")
    }

    var pathComponents: [String] { path.split(separator: "/").map(String.init) }

    var visibleEntries: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }

    // MARK: Paths

    func target(_ relative: String? = nil) -> String {
        guard let remote = selectedRemoteName else { return "" }
        return "\(remote):\(relative ?? path)"
    }

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : "\(a)/\(b)"
    }

    // MARK: Loading

    func loadRemotes() async {
        do {
            remotes = try await Rclone.remotes()
            remotesError = nil
            rcloneMissing = false
            if selectedRemoteName == nil || !remotes.contains(where: { $0.name == selectedRemoteName }) {
                selectedRemoteName = remotes.first?.name
            }
        } catch RcloneError.notFound {
            rcloneMissing = true
            remotes = []
        } catch {
            remotesError = error.localizedDescription
        }
    }

    func reload() async {
        guard selectedRemoteName != nil else { entries = []; return }
        let requested = target()
        let dir = path
        if let cached = listCache[requested] {
            if entriesTarget != requested { entries = cached; entriesTarget = requested; refreshCacheStatus() }
        } else if entriesTarget != requested {
            entries = []
            entriesTarget = requested
            cachedIDs = []
            cachedSizes = [:]
        }
        isLoading = true
        listError = nil
        defer { isLoading = false }
        do {
            // lsjson paths are relative to the listed folder; make them relative to the remote root.
            let result = try await listEntries(requested, remote: selectedRemoteName ?? "", dir: dir).map { entry -> Entry in
                var e = entry
                e.path = Self.join(dir, entry.name)
                return e
            }
            if listCache.count > 500 { listCache.removeAll() }
            listCache[requested] = result
            guard requested == target() else { return } // user navigated away meanwhile
            if result != entries { entries = result }
            selection = selection.filter { id in result.contains { $0.id == id } }
            refreshCacheStatus()
        } catch {
            listCache[requested] = nil
            guard requested == target() else { return }
            entries = []
            listError = error.localizedDescription
        }
    }

    func loadAbout() async {
        guard let remote = selectedRemoteName else { about = nil; return }
        about = nil
        var result = try? await RcloneDaemon.shared.about(remote: remote)
        if result == nil { result = try? await Rclone.about(remote) }
        if remote == selectedRemoteName { about = result }
    }

    /// Lists through the background rclone (fast); falls back to a one-shot process if it's unavailable.
    private func listEntries(_ target: String, remote: String, dir: String) async throws -> [Entry] {
        do {
            return try await RcloneDaemon.shared.list(remote: remote, path: dir)
        } catch where DaemonUnavailable.matches(error) {
            return try await Rclone.list(target)
        }
    }

    // MARK: Navigation

    func navigate(to newPath: String) {
        guard newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        go(newPath)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        go(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        go(next)
    }

    func goUp() {
        guard !path.isEmpty else { return }
        navigate(to: pathComponents.dropLast().joined(separator: "/"))
    }

    private func go(_ newPath: String) {
        path = newPath
        selection.removeAll()
        searchText = ""
        Task { await reload() }
    }

    func open(_ entry: Entry) {
        if entry.isDir {
            navigate(to: Self.join(path, entry.name))
        } else {
            preview(entry)
        }
    }

    // MARK: File operations

    private func perform(_ args: [String], refresh: Bool = true) async {
        do {
            _ = try await Rclone.run(args)
        } catch {
            alertMessage = error.localizedDescription
        }
        if refresh { await reload() }
    }

    func makeFolder(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await perform(["mkdir", target(Self.join(path, name))])
        selection = [Self.join(path, name)]
    }

    func rename(_ entry: Entry, to newName: String) async {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        let dest = target(Self.join(path, newName))
        await perform(["moveto", target(entry.path), dest])
    }

    /// Items being deleted ("remote:path"), shown dimmed with a spinner until they're gone.
    private(set) var deletingTargets: Set<String> = []
    /// Progress of the deletions in flight, for the status bar (reset when all are done).
    private(set) var deleteDone = 0
    private(set) var deleteTotal = 0

    func isDeleting(_ entry: Entry) -> Bool { deletingTargets.contains(target(entry.path)) }

    func delete(_ items: [Entry]) async {
        guard let remote = selectedRemoteName else { return }
        // Fix the targets now: the user may switch remotes or folders while this runs.
        let jobs = items.map { (entry: $0, target: target($0.path)) }.filter { !deletingTargets.contains($0.target) }
        guard !jobs.isEmpty else { return }
        deletingTargets.formUnion(jobs.map(\.target))
        deleteTotal += jobs.count
        selection.subtract(jobs.map(\.entry.id))
        for (item, itemTarget) in jobs {
            do {
                try await deleteItem(item, remote: remote, target: itemTarget)
            } catch {
                alertMessage = String(localized: "Couldn't delete “\(item.name)”: \(error.localizedDescription)")
                break
            }
            deletingTargets.remove(itemTarget)
            deleteDone += 1
            // Drop the row right away instead of waiting for the next listing.
            if target() == AppModel.parentTarget(of: itemTarget) { entries.removeAll { $0.id == item.id } }
            listCache[AppModel.parentTarget(of: itemTarget)]?.removeAll { $0.id == item.id }
        }
        deletingTargets.subtract(jobs.map(\.target))
        if deletingTargets.isEmpty { deleteDone = 0; deleteTotal = 0 }
        await reload()
        await loadAbout()
    }

    /// Deletes through the background rclone (reuses its connection); falls back to a one-shot process.
    private func deleteItem(_ item: Entry, remote: String, target: String) async throws {
        do {
            _ = try await RcloneDaemon.shared.call(item.isDir ? "operations/purge" : "operations/deletefile",
                                                   ["fs": "\(remote):", "remote": item.path])
        } catch where DaemonUnavailable.matches(error) {
            _ = try await Rclone.run(item.isDir ? ["purge", target] : ["deletefile", target])
        }
    }

    /// "remote:a/b/c" → "remote:a/b".
    private static func parentTarget(of target: String) -> String {
        guard let colon = target.firstIndex(of: ":") else { return target }
        let path = target[target.index(after: colon)...]
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return target[...colon] + parent
    }

    func copyPath(_ items: [Entry]) {
        let text = items.map { target($0.path) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Transfers

    private func startTransfer(_ transfer: Transfer, args: [String], then: ((Transfer) -> Void)? = nil) {
        startTransfer(transfer, then: then) { $0.start(args: args) }
    }

    private func startTransfer(_ transfer: Transfer, then: ((Transfer) -> Void)?, launch: (Transfer) -> Void) {
        transfers.insert(transfer, at: 0)
        transfer.onFinish = { [weak self] t in
            then?(t)
            guard let self else { return }
            if t.kind == .upload || t.kind == .copy || t.kind == .sync {
                Task { await self.reload(); await self.loadAbout() }
            }
        }
        launch(transfer)
    }

    func upload(_ urls: [URL]) {
        guard selectedRemoteName != nil else { return }
        let destDir = path
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let dest = isDir.boolValue ? target(Self.join(destDir, url.lastPathComponent)) : target(destDir)
            let t = Transfer(kind: .upload, title: url.lastPathComponent, detail: "→ \(dest)")
            startTransfer(t, args: ["copy", url.path, dest])
        }
    }

    func download(_ items: [Entry], to folder: URL) {
        for item in items {
            let local = item.isDir ? folder.appendingPathComponent(item.name) : folder
            let t = Transfer(kind: .download, title: item.name, detail: "→ \(folder.path)",
                             localURL: folder.appendingPathComponent(item.name), remoteTarget: target(item.path))
            startTransfer(t, args: ["copy", target(item.path), local.path])
        }
    }

    /// Opens a remote file with its default app, via the local file cache.
    func preview(_ entry: Entry) {
        fetchToCache(entry, forPreview: false) { NSWorkspace.shared.open($0) }
    }

    // MARK: Quick Look

    /// Local file currently shown in the Quick Look panel (nil = panel closed).
    var quickLookURL: URL?
    /// Remote path being fetched for Quick Look; a newer request supersedes it.
    @ObservationIgnored private var pendingQuickLook: String?

    /// Shows a file in Quick Look (like pressing Space in Finder), fetching it into the cache first.
    func quickLook(_ entry: Entry) {
        guard !entry.isDir else { return }
        let key = target(entry.path)
        pendingQuickLook = key
        fetchToCache(entry, forPreview: true) { [weak self] url in
            guard let self, self.pendingQuickLook == key else { return }
            self.pendingQuickLook = nil
            self.present(url)
        }
    }

    /// Whether the Quick Look panel is really on screen. The panel can be closed from its own
    /// window (Space, Esc, close button) without the binding being reset, so ask the panel.
    var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Shows `url` in Quick Look. SwiftUI only presents the panel when the bound URL *changes*;
    /// a cached file can resolve synchronously (or repeat the previous URL), so when the panel
    /// isn't already on screen, clear the binding and set it again on the next run-loop turn.
    private func present(_ url: URL) {
        if isQuickLookVisible {
            quickLookURL = url
        } else {
            quickLookURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.quickLookURL = url }
        }
    }

    func toggleQuickLook() {
        if isQuickLookVisible || pendingQuickLook != nil {
            quickLookURL = nil
            pendingQuickLook = nil
            if isQuickLookVisible { QLPreviewPanel.shared().orderOut(nil) }
        } else if selectedEntries.count == 1 {
            quickLookURL = nil // clear a stale value left by a panel closed from its own window
            quickLook(selectedEntries[0])
        }
    }

    /// Brings a remote file into the local cache, then calls `completion` with its local URL.
    /// `rclone copyto` skips the download when the cached copy still matches the remote.
    private func fetchToCache(_ entry: Entry, forPreview: Bool, completion: @escaping (URL) -> Void) {
        guard let remote = selectedRemoteName else { return }
        let fm = FileManager.default
        let file = FileCache.url(remote: remote, path: entry.path)
            ?? fm.temporaryDirectory.appendingPathComponent("RcloneGUI/\(UUID().uuidString)/\(entry.name)")
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Instant path: the folder listing already tells us the remote size and modification time,
        // and rclone stamps cached copies with the remote time — if both match, skip rclone entirely.
        if Self.cachedCopyMatches(file, entry, sizeOnly: sizeOnlyRemotes[remote] == true) {
            FileCache.markUsed(file)
            completion(file)
            return
        }

        let wasCached = fm.fileExists(atPath: file.path)
        let t = Transfer(kind: .open, title: entry.name,
                         detail: forPreview ? String(localized: "Loading preview…") : String(localized: "Opening…"),
                         localURL: file, remoteTarget: target(entry.path))
        loading = t
        loadingMessage = forPreview ? String(localized: "Loading preview of “\(entry.name)”…")
            : String(localized: "Opening “\(entry.name)”…")
        loadingEntryID = entry.id
        let finish: (Transfer) -> Void = { [weak self] t in
            if let self, self.loading === t { self.loading = nil; self.loadingEntryID = nil }
            let available = fm.fileExists(atPath: file.path)
            if t.state == .done {
                if wasCached && t.totalBytes == 0 {
                    t.note = forPreview ? String(localized: "Previewed from cache") : String(localized: "Opened from cache")
                }
            } else if case .failed = t.state, wasCached, available {
                // Remote unreachable: fall back to the last cached copy.
                t.state = .done
                t.note = forPreview ? String(localized: "Offline — previewed the cached copy")
                    : String(localized: "Offline — opened the cached copy")
            } else {
                return
            }
            FileCache.markUsed(file)
            completion(file)
            self?.refreshCacheStatus()
            Task.detached(priority: .utility) {
                FileCache.enforceLimit(keeping: file)
                await self?.refreshCacheStatus()
            }
        }
        startTransfer(t, then: finish) { t in
            t.startJob("operations/copyfile", [
                "srcFs": "\(remote):", "srcRemote": entry.path,
                "dstFs": file.deletingLastPathComponent().path, "dstRemote": file.lastPathComponent,
            ], fallbackArgs: ["copyto", target(entry.path), file.path])
        }
    }

    /// Whether the cached copy still matches the remote item. Normally size + modification time;
    /// for items without a fixed size (Google Docs/Sheets/Slides, exported on download) the cached
    /// export's size can't be compared, so the modification time alone decides. On remotes that
    /// can't keep modification times (`sizeOnly`), the listed time isn't stable, so — like rclone
    /// itself on those remotes — only the size is compared.
    nonisolated private static func cachedCopyMatches(_ file: URL, _ entry: Entry, sizeOnly: Bool) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { return false }
        let size = (attrs[.size] as? NSNumber)?.int64Value
        if sizeOnly { return entry.size >= 0 && size == entry.size }
        guard entry.modTime != .distantPast,
              let modified = attrs[.modificationDate] as? Date,
              abs(modified.timeIntervalSince(entry.modTime)) < 1 else { return false }
        return entry.size < 0 || size == entry.size
    }

    /// Remotes whose modification times rclone says are unsupported, so the cache compares sizes only.
    @ObservationIgnored private var sizeOnlyRemotes: [String: Bool] = [:]

    private func checkModTimeSupport() async {
        guard let remote = selectedRemoteName, sizeOnlyRemotes[remote] == nil,
              let unsupported = try? await RcloneDaemon.shared.modTimeUnsupported(remote: remote) else { return }
        sizeOnlyRemotes[remote] = unsupported
        if unsupported, remote == selectedRemoteName { refreshCacheStatus() }
    }

    // MARK: Per-file status

    /// Rows in the current folder whose cached copy matches the remote (opens instantly).
    var cachedIDs: Set<Entry.ID> = []
    /// For items the remote can't size (e.g. Google Docs): the size of the cached exported copy.
    var cachedSizes: [Entry.ID: Int64] = [:]

    /// Re-checks which listed files have an up-to-date cached copy (off the main thread).
    func refreshCacheStatus() {
        guard let remote = selectedRemoteName else { cachedIDs = []; cachedSizes = [:]; return }
        let files = entries.filter { !$0.isDir }
        let shownTarget = target()
        let sizeOnly = sizeOnlyRemotes[remote] == true
        Task {
            let (ids, sizes) = await Task.detached(priority: .utility) { () -> (Set<Entry.ID>, [Entry.ID: Int64]) in
                var ids = Set<Entry.ID>(), sizes = [Entry.ID: Int64]()
                for e in files {
                    guard let url = FileCache.url(remote: remote, path: e.path),
                          AppModel.cachedCopyMatches(url, e, sizeOnly: sizeOnly) else { continue }
                    ids.insert(e.id)
                    if e.size < 0, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                        sizes[e.id] = size.int64Value
                    }
                }
                return (ids, sizes)
            }.value
            if shownTarget == target() { cachedIDs = ids; cachedSizes = sizes }
        }
    }

    /// A running transfer reading this row's remote item (download, open or preview), if any.
    func activeTransfer(for entry: Entry) -> Transfer? {
        let t = target(entry.path)
        return transfers.first { $0.isRunning && $0.remoteTarget == t }
    }

    /// The open/preview fetch currently shown in the loading overlay.
    var loading: Transfer?
    /// What the loading overlay says, e.g. "Opening “report.pdf”…".
    var loadingMessage = ""
    var loadingEntryID: Entry.ID?

    func cancelLoading() {
        loading?.cancel()
        loading = nil
        loadingEntryID = nil
        pendingQuickLook = nil
    }

    /// Lists a transfer started elsewhere (e.g. a sync task) in the transfers panel.
    func adoptTransfer(_ transfer: Transfer) {
        transfers.insert(transfer, at: 0)
    }

    func clearFinishedTransfers() {
        transfers.removeAll { !$0.isRunning }
    }

    // MARK: Remotes management

    func deleteRemote(_ name: String) async {
        do {
            _ = try await Rclone.run(["config", "delete", name])
        } catch {
            alertMessage = error.localizedDescription
        }
        if selectedRemoteName == name { selectedRemoteName = nil }
        await loadRemotes()
    }
}
