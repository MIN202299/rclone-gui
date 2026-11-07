import CoreServices
import Foundation
import Observation

/// A saved pairing of a local folder with a remote folder that can be synced again and again.
struct SyncTask: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case upload    // local → remote mirror
        case download  // remote → local mirror
        case twoWay    // rclone bisync
        var id: String { rawValue }

        var title: String {
            switch self {
            case .upload: return "Upload"
            case .download: return "Download"
            case .twoWay: return "Two-way"
            }
        }

        var symbol: String {
            switch self {
            case .upload: return "icloud.and.arrow.up"
            case .download: return "icloud.and.arrow.down"
            case .twoWay: return "arrow.triangle.2.circlepath"
            }
        }

        var arrow: String {
            switch self {
            case .upload: return "→"
            case .download: return "←"
            case .twoWay: return "⇄"
            }
        }

        var explanation: String {
            switch self {
            case .upload:
                return "Makes the remote folder an exact copy of the local folder. Files you delete locally are also deleted on the remote."
            case .download:
                return "Makes the local folder an exact copy of the remote folder. Files deleted on the remote are also deleted locally."
            case .twoWay:
                return "Changes on either side, including deletions, are copied to the other side. If a file changed on both sides, the newer one wins and the other is kept with a numbered name. The first run merges both folders without deleting anything."
            }
        }
    }

    var id = UUID()
    var name: String
    var localPath: String
    var remote: String
    var remotePath: String
    var mode: Mode
    /// 0 = only when you click Sync Now.
    var intervalMinutes: Int = 0
    /// Also sync shortly after files in the local folder change (upload / two-way).
    var watchLocal = false
    var paused = false

    var lastRun: Date?
    var lastSuccess: Bool?
    var lastMessage: String?
    /// Two-way only: whether bisync's baseline exists; otherwise the next run uses --resync.
    var baselineReady = false

    var remoteTarget: String { "\(remote):\(remotePath)" }
    var localURL: URL { URL(fileURLWithPath: localPath, isDirectory: true) }
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    static let intervalChoices: [(minutes: Int, label: String)] = [
        (0, "Manually only"), (5, "Every 5 minutes"), (15, "Every 15 minutes"), (30, "Every 30 minutes"),
        (60, "Every hour"), (360, "Every 6 hours"), (1440, "Every day"),
    ]

    var scheduleText: String {
        var parts: [String] = []
        if intervalMinutes > 0, let label = Self.intervalChoices.first(where: { $0.minutes == intervalMinutes })?.label {
            parts.append(label.lowercased())
        }
        if watchLocal && mode != .download { parts.append("on local changes") }
        return parts.isEmpty ? "Manual" : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }
}

/// Stores sync tasks, runs them on demand, on a schedule, or when local files change.
@Observable @MainActor
final class SyncManager {
    static let shared = SyncManager()

    private(set) var tasks: [SyncTask] = []
    /// Transfers of tasks that are syncing right now.
    private(set) var running: [UUID: Transfer] = [:]
    /// Tasks whose last two-way run needs its baseline rebuilt.
    private(set) var needsRepair: Set<UUID> = []

    /// Hooks so the main window can list sync transfers and refresh affected folders.
    @ObservationIgnored var onTransferStarted: ((Transfer) -> Void)?
    @ObservationIgnored var onTaskFinished: ((SyncTask) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers: [UUID: LocalWatcher] = [:]
    @ObservationIgnored private var debounce: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var cooldownUntil: [UUID: Date] = [:]

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RcloneGUI", isDirectory: true)
    }
    private static var storeURL: URL { supportDir.appendingPathComponent("sync-tasks.json") }

    private init() {
        load()
        refreshWatchers()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { SyncManager.shared.runDueTasks() }
        }
        timer?.tolerance = 5
    }

    // MARK: Queries

    func task(_ id: UUID) -> SyncTask? { tasks.first { $0.id == id } }
    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// Tasks whose remote folder is exactly `target` ("remote:path").
    func tasks(forRemoteTarget target: String) -> [SyncTask] {
        tasks.filter { $0.remoteTarget == target }
    }

    func nextRun(_ task: SyncTask) -> Date? {
        guard task.intervalMinutes > 0, !task.paused else { return nil }
        return (task.lastRun ?? .distantPast).addingTimeInterval(Double(task.intervalMinutes) * 60)
    }

    // MARK: Editing

    /// Adds or updates a task. Changing a two-way task's folders resets its baseline.
    func save(_ task: SyncTask) {
        var task = task
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            let old = tasks[i]
            if old.localPath != task.localPath || old.remoteTarget != task.remoteTarget || old.mode != task.mode {
                task.baselineReady = false
                resetBisyncState(task)
            }
            tasks[i] = task
        } else {
            tasks.append(task)
        }
        persist()
        refreshWatchers()
    }

    func delete(_ id: UUID) {
        guard let task = task(id) else { return }
        running[id]?.cancel()
        tasks.removeAll { $0.id == id }
        resetBisyncState(task)
        persist()
        refreshWatchers()
    }

    func setPaused(_ id: UUID, _ paused: Bool) {
        update(id) { $0.paused = paused }
        refreshWatchers()
    }

    private func update(_ id: UUID, _ change: (inout SyncTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        persist()
    }

    // MARK: Running

    func cancel(_ id: UUID) { running[id]?.cancel() }

    /// Rebuilds a two-way task's baseline (merges both sides without deleting) and syncs.
    func repair(_ id: UUID) {
        guard let task = task(id) else { return }
        resetBisyncState(task)
        update(id) { $0.baselineReady = false }
        needsRepair.remove(id)
        run(id)
    }

    func run(_ id: UUID, automatic: Bool = false) {
        guard let task = task(id), running[id] == nil else { return }
        if automatic && task.paused { return }

        var isDir: ObjCBool = false
        let localExists = FileManager.default.fileExists(atPath: task.localPath, isDirectory: &isDir) && isDir.boolValue
        if !localExists && task.mode != .download {
            record(id, success: false, message: "The local folder “\(task.localPath)” can't be found.")
            return
        }

        Task {
            // Safety: never mirror an empty source over a full destination.
            if task.mode == .upload, (try? FileManager.default.contentsOfDirectory(atPath: task.localPath))?
                .filter({ !$0.hasPrefix(".") }).isEmpty ?? true {
                record(id, success: false, message: "Skipped: the local folder is empty, so syncing would delete everything on the remote.")
                return
            }
            if task.mode == .download,
               let list = try? await RcloneDaemon.shared.list(remote: task.remote, path: task.remotePath), list.isEmpty {
                record(id, success: false, message: "Skipped: the remote folder is empty, so syncing would delete everything in the local folder.")
                return
            }
            if task.mode == .download && !localExists {
                try? FileManager.default.createDirectory(atPath: task.localPath, withIntermediateDirectories: true)
            }
            start(task)
        }
    }

    private func start(_ task: SyncTask) {
        guard running[task.id] == nil else { return }
        let args: [String]
        switch task.mode {
        case .upload:
            args = ["sync", task.localPath, task.remoteTarget, "--create-empty-src-dirs"]
        case .download:
            args = ["sync", task.remoteTarget, task.localPath, "--create-empty-src-dirs"]
        case .twoWay:
            guard let link = bisyncLink(for: task) else {
                record(task.id, success: false, message: "Couldn't prepare the two-way sync state folder.")
                return
            }
            // bisync's state file is named "<path1>..<path2>.path1.lst" and must fit in 255 bytes.
            let stateName = (link.path.dropFirst() + ".." + task.remoteTarget + ".path1.lst")
                .replacingOccurrences(of: "/", with: "_")
            if stateName.utf8.count > 250 {
                record(task.id, success: false,
                       message: "The remote folder path is too long for two-way sync (an rclone limit). Choose a shorter remote folder, or use one-way sync.")
                return
            }
            var a = ["bisync", link.path, task.remoteTarget,
                     "--resilient", "--recover", "--max-lock", "2m",
                     "--conflict-resolve", "newer", "--conflict-loser", "num",
                     "--compare", "size,modtime", "--create-empty-src-dirs",
                     "--workdir", bisyncWorkdir(for: task).path]
            if !task.baselineReady { a += ["--resync", "--resync-mode", "newer"] }
            args = a
        }

        let t = Transfer(kind: .sync, title: task.name,
                         detail: "\(Self.displayPath(task.localPath)) \(task.mode.arrow) \(task.remoteTarget)",
                         localURL: task.localURL, remoteTarget: task.remoteTarget)
        running[task.id] = t
        onTransferStarted?(t)
        t.onFinish = { [weak self] t in
            guard let self else { return }
            self.running[task.id] = nil
            self.cooldownUntil[task.id] = Date().addingTimeInterval(8) // ignore our own local writes
            switch t.state {
            case .done:
                self.update(task.id) { $0.baselineReady = true }
                self.needsRepair.remove(task.id)
                self.record(task.id, success: true, message: Self.summary(t))
            case .failed(let message):
                if task.mode == .twoWay && message.localizedCaseInsensitiveContains("resync") {
                    self.needsRepair.insert(task.id)
                }
                self.record(task.id, success: false, message: message)
            case .cancelled:
                self.record(task.id, success: false, message: "Cancelled")
            case .running:
                break
            }
            if let updated = self.task(task.id) { self.onTaskFinished?(updated) }
        }
        t.start(args: args)
    }

    private func record(_ id: UUID, success: Bool, message: String) {
        update(id) {
            $0.lastRun = Date()
            $0.lastSuccess = success
            $0.lastMessage = message
        }
    }

    private static func summary(_ t: Transfer) -> String {
        var parts: [String] = []
        if t.totalFiles > 0 { parts.append("\(t.totalFiles) file\(t.totalFiles == 1 ? "" : "s") copied") }
        if t.totalBytes > 0 { parts.append(t.totalBytes.byteString) }
        if t.deletes > 0 { parts.append("\(t.deletes) deleted") }
        return parts.isEmpty ? "Already in sync" : parts.joined(separator: " · ")
    }

    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Two-way state

    /// bisync names its state files after both paths, which can exceed macOS's 255-byte file name
    /// limit; syncing through a short symlink to the local folder keeps them short.
    private func bisyncLink(for task: SyncTask) -> URL? {
        let fm = FileManager.default
        let dir = Self.supportDir.appendingPathComponent("sync-links", isDirectory: true)
        let link = dir.appendingPathComponent(task.shortID)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != task.localPath {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: task.localPath)
            }
            return link
        } catch {
            return nil
        }
    }

    private func bisyncWorkdir(for task: SyncTask) -> URL {
        Self.supportDir.appendingPathComponent("bisync/\(task.shortID)", isDirectory: true)
    }

    private func resetBisyncState(_ task: SyncTask) {
        try? FileManager.default.removeItem(at: bisyncWorkdir(for: task))
    }

    // MARK: Automation

    private func runDueTasks() {
        let now = Date()
        for task in tasks where !task.paused && running[task.id] == nil {
            if let next = nextRun(task), next <= now { run(task.id, automatic: true) }
        }
    }

    private func refreshWatchers() {
        let wanted = Set(tasks.filter { $0.watchLocal && !$0.paused && $0.mode != .download }.map(\.id))
        for id in watchers.keys where !wanted.contains(id) { watchers[id] = nil }
        for id in wanted {
            guard let task = task(id) else { continue }
            if let w = watchers[id], w.path == task.localPath { continue }
            watchers[id] = LocalWatcher(path: task.localPath) { [weak self] in self?.localChanged(id) }
        }
    }

    private func localChanged(_ id: UUID) {
        if running[id] != nil { return }
        if let until = cooldownUntil[id], until > Date() { return }
        debounce[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run(id, automatic: true) }
        }
        debounce[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work) // let edits settle
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tasks = (try? decoder.decode([SyncTask].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tasks) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

/// Watches a folder tree with FSEvents and calls `onChange` (on the main queue) when anything changes.
final class LocalWatcher {
    let path: String
    private var stream: FSEventStreamRef?
    private let box: Unmanaged<Callback>

    private final class Callback {
        let fn: () -> Void
        init(_ fn: @escaping () -> Void) { self.fn = fn }
    }

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        box = Unmanaged.passRetained(Callback(onChange))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().fn()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        box.release()
    }
}
