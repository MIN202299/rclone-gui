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

    /// The rclone target for a path on the selected remote. Inside an unlocked encrypted backup this
    /// goes through its crypt remote ("rgcrypt_…:sub/path"), so files are decrypted on the way.
    func target(_ relative: String? = nil) -> String {
        let loc = location(relative ?? path)
        return loc.fs.isEmpty ? "" : loc.fs + loc.remote
    }

    /// The plain "remote:path" to show people (and to match backup tasks), never the crypt alias.
    func displayTarget(_ relative: String? = nil) -> String {
        guard let remote = selectedRemoteName else { return "" }
        return "\(remote):\(relative ?? path)"
    }

    /// The rclone fs ("remote:" or "rgcrypt_…:") and the path inside it for a path on the selected remote.
    func location(_ relative: String) -> (fs: String, remote: String) {
        guard let remote = selectedRemoteName else { return ("", relative) }
        if let folder = cryptFolder(for: relative) { return ("\(folder.alias):", Self.subpath(relative, of: folder.path)) }
        return ("\(remote):", relative)
    }

    /// `path` relative to `root` (both relative to the remote root; `path` must be inside `root`).
    static func subpath(_ path: String, of root: String) -> String {
        if root.isEmpty || path == root { return root.isEmpty ? path : "" }
        return String(path.dropFirst(root.count + 1))
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        root.isEmpty || path == root || path.hasPrefix(root + "/")
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
            var result = try await listEntries(requested, remote: selectedRemoteName ?? "", dir: dir).map { entry -> Entry in
                var e = entry
                e.path = Self.join(dir, entry.name)
                return e
            }
            // A folder holding an encrypted backup: its files are unreadable until it's unlocked.
            let plain = displayTarget(dir)
            if cryptFolder(for: dir) == nil, result.contains(where: { !$0.isDir && $0.name == CryptMarker.fileName }) {
                knownEncrypted.insert(plain)
                result = []
            } else if cryptFolder(for: dir) == nil {
                knownEncrypted.remove(plain)
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
            let loc = location(dir)
            return try await RcloneDaemon.shared.list(fs: loc.fs, path: loc.remote)
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
            let loc = location(item.path)
            _ = try await RcloneDaemon.shared.call(item.isDir ? "operations/purge" : "operations/deletefile",
                                                   ["fs": loc.fs, "remote": loc.remote])
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
        let text = items.map { displayTarget($0.path) }.joined(separator: "\n")
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
            let destPath = isDir.boolValue ? Self.join(destDir, url.lastPathComponent) : destDir
            let dest = target(destPath)
            let t = Transfer(kind: .upload, title: url.lastPathComponent, detail: "→ \(displayTarget(destPath))")
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
        let file = FileCache.url(remote: cacheName(for: entry.path), path: entry.path)
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
        let loc = location(entry.path)
        startTransfer(t, then: finish) { t in
            t.startJob("operations/copyfile", [
                "srcFs": loc.fs, "srcRemote": loc.remote,
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
        let cacheRemote = cacheName(for: path)
        Task {
            let (ids, sizes) = await Task.detached(priority: .utility) { () -> (Set<Entry.ID>, [Entry.ID: Int64]) in
                var ids = Set<Entry.ID>(), sizes = [Entry.ID: Int64]()
                for e in files {
                    guard let url = FileCache.url(remote: cacheRemote, path: e.path),
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

    // MARK: Encrypted backups

    /// Encrypted backup folders unlocked this session, by their plain "remote:path".
    private(set) var unlockedFolders: [String: CryptFolder] = [:]
    /// Plain targets of folders seen to hold an encrypted backup.
    private(set) var knownEncrypted: Set<String> = []

    /// The unlocked encrypted folder `relative` is in, if any (the innermost one).
    func cryptFolder(for relative: String) -> CryptFolder? {
        guard let remote = selectedRemoteName else { return nil }
        return unlockedFolders.values
            .filter { $0.remote == remote && Self.isInside(relative, $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    /// The unlocked encrypted backup the open folder is in.
    var currentCryptFolder: CryptFolder? { cryptFolder(for: path) }

    /// The open folder is an encrypted backup that hasn't been unlocked; its files aren't listed.
    var isLockedHere: Bool { currentCryptFolder == nil && knownEncrypted.contains(displayTarget()) }

    /// Whether a listed folder is an encrypted backup (seen before, or the target of an encrypted task).
    func isEncryptedFolder(_ entry: Entry) -> Bool {
        guard entry.isDir, currentCryptFolder == nil else { return false }
        let plain = displayTarget(entry.path)
        return knownEncrypted.contains(plain)
            || SyncManager.shared.tasks.contains { $0.encrypted && $0.remoteTarget == plain }
    }

    /// Decrypted files are cached apart from the remote's own files, so locking can remove them.
    private func cacheName(for relative: String) -> String {
        let remote = selectedRemoteName ?? ""
        return cryptFolder(for: relative) == nil ? remote : remote + " (encrypted)"
    }

    /// Unlocks an encrypted backup on the selected remote (the open folder unless `root` is given).
    func unlock(password: String, remember: Bool, at root: String? = nil) async throws {
        guard let remote = selectedRemoteName else { return }
        let root = root ?? path
        guard let marker = try await Crypt.readMarker(remote: remote, path: root) else {
            throw CryptError.notEncrypted(displayTarget(root))
        }
        let folder = try await Crypt.open(remote: remote, path: root, marker: marker, password: password)
        if remember { CryptKeychain.setPassword(password, CryptKeychain.folderAccount(folder.plainTarget)) }
        guard unlockedFolders[folder.plainTarget] == nil else { return }
        CryptAliases.shared.register(folder)
        unlockedFolders[folder.plainTarget] = folder
        if selectedRemoteName == remote && path == root { await reload() }
    }

    /// Passwords in the keychain that may open a folder: one remembered when it was unlocked
    /// before, and those of encrypted backup tasks for it.
    private func savedPasswords(_ root: String) -> [String] {
        let plain = displayTarget(root)
        let tasks = SyncManager.shared.tasks.filter { $0.encrypted && $0.remoteTarget == plain }
        let accounts = [CryptKeychain.folderAccount(plain)] + tasks.map { CryptKeychain.taskAccount($0.id) }
        var seen = Set<String>()
        return accounts.compactMap(CryptKeychain.password).filter { seen.insert($0).inserted }
    }

    /// Tries the saved passwords; true if one of them unlocked the folder (the open one by default).
    func unlockWithSavedPassword(at root: String? = nil) async -> Bool {
        for password in savedPasswords(root ?? path) {
            do {
                try await unlock(password: password, remember: false, at: root)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    var hasRememberedPassword: Bool {
        guard let folder = currentCryptFolder else { return false }
        return CryptKeychain.password(CryptKeychain.folderAccount(folder.plainTarget)) != nil
    }

    /// Locks an unlocked encrypted backup: forgets its key, removes decrypted copies cached on this
    /// Mac, and returns to the folder itself if the browser is inside it.
    func lock(_ folder: CryptFolder, forgetPassword: Bool = false) async {
        guard unlockedFolders.removeValue(forKey: folder.plainTarget) != nil else { return }
        CryptAliases.shared.unregister(folder)
        if forgetPassword { CryptKeychain.delete(CryptKeychain.folderAccount(folder.plainTarget)) }
        listCache = listCache.filter { !$0.key.hasPrefix(folder.alias + ":") }
        FileCache.removeFolder(remote: folder.remote + " (encrypted)", path: folder.path)
        if quickLookURL != nil { quickLookURL = nil }
        if selectedRemoteName == folder.remote {
            let inside = { (p: String) in Self.isInside(p, folder.path) && p != folder.path }
            backStack.removeAll(where: inside)
            forwardStack.removeAll(where: inside)
            if Self.isInside(path, folder.path) {
                path = folder.path
                selection.removeAll()
                searchText = ""
            }
        }
        await Crypt.forgetOpenFolders()
        await reload()
    }

    /// A new backup task for the open folder; inside an encrypted backup it targets the backup itself.
    func backupTaskForCurrentFolder() -> SyncTask {
        let remote = selectedRemoteName ?? remotes.first?.name ?? ""
        let encryptedRoot = currentCryptFolder?.path ?? (isLockedHere ? path : nil)
        let folderPath = selectedRemoteName == nil ? "" : (encryptedRoot ?? path)
        let name = folderPath.split(separator: "/").last.map(String.init) ?? remote
        var task = SyncTask(name: name, localPath: "", remote: remote, remotePath: folderPath, mode: .upload)
        task.encrypted = encryptedRoot != nil
        return task
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
