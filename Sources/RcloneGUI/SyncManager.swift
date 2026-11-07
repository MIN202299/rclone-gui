import CoreServices
import Foundation
import Observation

/// A saved pairing of a local folder with a remote folder that can be backed up again and again.
/// Backups only copy new and changed files (`rclone copy`); they never delete anything.
struct SyncTask: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case upload    // local → remote
        case download  // remote → local
        var id: String { rawValue }

        /// Tasks saved by older versions may say "twoWay"; they become upload backups.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .upload
        }

        var title: String {
            switch self {
            case .upload: return String(localized: "Upload")
            case .download: return String(localized: "Download")
            }
        }

        var symbol: String {
            switch self {
            case .upload: return "icloud.and.arrow.up"
            case .download: return "icloud.and.arrow.down"
            }
        }

        var arrow: String {
            switch self {
            case .upload: return "→"
            case .download: return "←"
            }
        }

        var explanation: String {
            switch self {
            case .upload:
                return String(localized: "Copies new and changed files from the local folder to the remote folder. Nothing is ever deleted: files you delete locally stay on the remote, and the local folder is never changed.")
            case .download:
                return String(localized: "Copies new and changed files from the remote folder to the local folder. Nothing is ever deleted: files deleted on the remote stay in the local folder, and the remote is never changed.")
            }
        }
    }

    var id = UUID()
    var name: String
    var localPath: String
    var remote: String
    var remotePath: String
    var mode: Mode
    /// 0 = only when you click Back Up Now.
    var intervalMinutes: Int = 0
    /// Also back up shortly after files in the local folder change (upload only).
    var watchLocal = false
    var paused = false

    var lastRun: Date?
    var lastSuccess: Bool?
    var lastMessage: String?

    var remoteTarget: String { "\(remote):\(remotePath)" }
    var localURL: URL { URL(fileURLWithPath: localPath, isDirectory: true) }
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    static var intervalChoices: [(minutes: Int, label: String)] {
        [
            (0, String(localized: "Manually only")),
            (5, String(localized: "Every 5 minutes")),
            (15, String(localized: "Every 15 minutes")),
            (30, String(localized: "Every 30 minutes")),
            (60, String(localized: "Every hour")),
            (360, String(localized: "Every 6 hours")),
            (1440, String(localized: "Every day")),
        ]
    }

    var scheduleText: String {
        var parts: [String] = []
        if intervalMinutes > 0, let label = Self.intervalChoices.first(where: { $0.minutes == intervalMinutes })?.label {
            parts.append(label)
        }
        if watchLocal && mode != .download {
            // "Every hour · on local changes", or "On local changes" on its own.
            parts.append(parts.isEmpty ? String(localized: "On local changes") : String(localized: "on local changes"))
        }
        return parts.isEmpty ? String(localized: "Manual") : parts.joined(separator: " · ")
    }
}

/// Stores backup tasks, runs them on demand, on a schedule, or when local files change.
@Observable @MainActor
final class SyncManager {
    static let shared = SyncManager()

    private(set) var tasks: [SyncTask] = []
    /// Transfers of tasks that are backing up right now.
    private(set) var running: [UUID: Transfer] = [:]

    /// Hooks so the main window can list backup transfers and refresh affected folders.
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
        removeTwoWayLeftovers()
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

    /// Adds or updates a task.
    func save(_ task: SyncTask) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i] = task
        } else {
            tasks.append(task)
        }
        persist()
        refreshWatchers()
    }

    func delete(_ id: UUID) {
        guard task(id) != nil else { return }
        running[id]?.cancel()
        tasks.removeAll { $0.id == id }
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

    /// Stops every running backup (used when the app quits, so no rclone keeps running unseen).
    func cancelAll() { running.values.forEach { $0.cancel() } }

    func run(_ id: UUID, automatic: Bool = false) {
        guard let task = task(id), running[id] == nil else { return }
        if automatic && task.paused { return }

        var isDir: ObjCBool = false
        let localExists = FileManager.default.fileExists(atPath: task.localPath, isDirectory: &isDir) && isDir.boolValue
        if !localExists && task.mode != .download {
            record(id, success: false, message: String(localized: "The local folder “\(task.localPath)” can't be found."))
            return
        }

        if task.mode == .download && !localExists {
            try? FileManager.default.createDirectory(atPath: task.localPath, withIntermediateDirectories: true)
        }
        start(task)
    }

    private func start(_ task: SyncTask) {
        guard running[task.id] == nil else { return }
        // `copy` never deletes from the destination, so emptied or missing files never spread.
        let args: [String]
        switch task.mode {
        case .upload:
            args = ["copy", task.localPath, task.remoteTarget, "--create-empty-src-dirs"]
        case .download:
            args = ["copy", task.remoteTarget, task.localPath, "--create-empty-src-dirs"]
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
                self.record(task.id, success: true, message: Self.summary(t))
            case .failed(let message):
                self.record(task.id, success: false, message: message)
            case .cancelled:
                self.record(task.id, success: false, message: String(localized: "Cancelled"))
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
        if t.totalFiles > 0 {
            parts.append(t.totalFiles == 1 ? String(localized: "1 file copied") : String(localized: "\(t.totalFiles) files copied"))
        }
        if t.totalBytes > 0 { parts.append(t.totalBytes.byteString) }
        return parts.isEmpty ? String(localized: "Already up to date") : parts.joined(separator: " · ")
    }

    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Removes the state folders that two-way sync (no longer offered) kept for each task.
    private func removeTwoWayLeftovers() {
        for name in ["bisync", "sync-links"] {
            try? FileManager.default.removeItem(at: Self.supportDir.appendingPathComponent(name, isDirectory: true))
        }
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
