import Foundation
import Observation

/// A long-running rclone job (copy/upload/download) with live progress parsed from JSON logs.
@Observable @MainActor
final class Transfer: Identifiable {
    enum Kind { case upload, download, open, copy, sync }
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    /// Local folder or file this transfer produces, for "Show in Finder".
    let localURL: URL?

    var state: State = .running
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var eta: Double?
    var files = 0
    var totalFiles = 0
    var deletes = 0
    /// Overrides the status line once finished (e.g. "Opened from cache").
    var note: String?
    var started = Date()

    var onFinish: ((Transfer) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var jobID: Int?
    @ObservationIgnored private var errors: [String] = []

    /// The remote item this transfer reads (e.g. "Google Drive:Photos/a.jpg"), so the file list
    /// can show its progress on the matching row.
    let remoteTarget: String?

    init(kind: Kind, title: String, detail: String, localURL: URL? = nil, remoteTarget: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.localURL = localURL
        self.remoteTarget = remoteTarget
    }

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytes) / Double(totalBytes))
    }

    var isRunning: Bool { state == .running }

    var symbol: String {
        switch kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .open: return "eye.circle"
        case .copy: return "doc.on.doc"
        case .sync: return "externaldrive.badge.timemachine"
        }
    }

    var statusText: String {
        if let note, !isRunning { return note }
        switch state {
        case .running:
            guard totalBytes > 0 else {
                return kind == .sync ? String(localized: "Comparing files…") : String(localized: "Connecting…")
            }
            var s = String(localized: "\(bytes.byteString) of \(totalBytes.byteString)")
            if totalFiles > 1 { s += " · " + String(localized: "\(files)/\(totalFiles) files") }
            if speed > 0 { s += " · \(Int64(speed).byteString)/s" }
            if let eta, eta > 0 { s += " · " + String(localized: "\(Self.etaFormatter.string(from: eta) ?? "") left") }
            return s
        case .done:
            var s = totalBytes > 0 ? String(localized: "Completed · \(totalBytes.byteString)")
                : kind == .sync ? String(localized: "Already up to date") : String(localized: "Completed")
            if totalFiles > 0 { s += " · " + (totalFiles == 1 ? String(localized: "1 file") : String(localized: "\(totalFiles) files")) }
            if deletes > 0 { s += " · " + String(localized: "\(deletes) deleted") }
            return s
        case .failed(let msg): return msg
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()

    func start(args: [String]) {
        guard let exe = Rclone.locate() else {
            state = .failed(RcloneError.notFound.localizedDescription)
            onFinish?(self)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args + ["--use-json-log", "--stats", "500ms", "--stats-log-level", "NOTICE"]
        if let env = rcloneEnvironment(for: args) { p.environment = env }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err

        let buffer = LineBuffer()
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let lines = buffer.append(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor in self?.consume(lines) }
        }
        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            let rest = buffer.append(err.fileHandleForReading.readDataToEndOfFile()) + buffer.flush()
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                guard let self else { return }
                self.consume(rest)
                self.finish(status: status, reason: reason)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
            onFinish?(self)
        }
    }

    func cancel() {
        guard isRunning else { return }
        state = .cancelled
        process?.terminate()
        if let jobID { Task { _ = try? await RcloneDaemon.shared.call("job/stop", ["jobid": jobID]) } }
    }

    /// Runs a remote-control command as an async job on the background rclone, polling for
    /// progress. Much faster than a fresh process for small operations on slow-to-connect remotes.
    func startJob(_ command: String, _ params: [String: Any], fallbackArgs: [String]? = nil) {
        Task { @MainActor in
            let daemon = RcloneDaemon.shared
            do {
                var p = params
                p["_async"] = true
                let r = try await daemon.call(command, p)
                guard let id = (r["jobid"] as? NSNumber)?.intValue else {
                    throw RcloneError.failed(String(localized: "rclone didn't start the job."))
                }
                jobID = id
                while true {
                    let status = try await daemon.call("job/status", ["jobid": id])
                    if let stats = try? await daemon.call("core/stats", ["group": "job/\(id)"]) { apply(stats) }
                    if (status["finished"] as? Bool) == true {
                        if state == .running {
                            if (status["success"] as? Bool) == true {
                                state = .done
                                if totalBytes > 0 { bytes = totalBytes }
                            } else {
                                state = .failed((status["error"] as? String) ?? String(localized: "rclone reported an error."))
                            }
                        }
                        break
                    }
                    if state != .running { break } // cancelled
                    try await Task.sleep(for: .milliseconds(120))
                }
            } catch {
                if jobID == nil, DaemonUnavailable.matches(error), let fallbackArgs, state == .running {
                    start(args: fallbackArgs) // background rclone unavailable: use a one-shot process
                    return
                }
                if state == .running { state = .failed(error.localizedDescription) }
            }
            jobID = nil
            onFinish?(self)
        }
    }

    private func apply(_ stats: [String: Any]) {
        var total = (stats["totalBytes"] as? NSNumber)?.int64Value ?? 0
        // While a single file is in flight, its size is the most reliable total.
        if let transferring = stats["transferring"] as? [[String: Any]], !transferring.isEmpty {
            let inFlight = transferring.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
            total = max(total, inFlight)
        }
        if total > 0 { totalBytes = total }
        bytes = (stats["bytes"] as? NSNumber)?.int64Value ?? bytes
        speed = (stats["speed"] as? NSNumber)?.doubleValue ?? 0
        eta = (stats["eta"] as? NSNumber)?.doubleValue
    }

    private func consume(_ lines: [String]) {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let stats = obj["stats"] as? [String: Any] {
                bytes = (stats["bytes"] as? NSNumber)?.int64Value ?? bytes
                totalBytes = (stats["totalBytes"] as? NSNumber)?.int64Value ?? totalBytes
                speed = (stats["speed"] as? NSNumber)?.doubleValue ?? 0
                eta = (stats["eta"] as? NSNumber)?.doubleValue
                files = (stats["transfers"] as? NSNumber)?.intValue ?? files
                totalFiles = (stats["totalTransfers"] as? NSNumber)?.intValue ?? totalFiles
                deletes = (stats["deletes"] as? NSNumber)?.intValue ?? deletes
            } else if let level = obj["level"] as? String, level == "error" || level == "critical",
                      let msg = obj["msg"] as? String {
                errors.append(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func finish(status: Int32, reason: Process.TerminationReason) {
        process = nil
        if state == .running {
            if status == 0 {
                state = .done
                if totalBytes > 0 { bytes = totalBytes }
            } else {
                state = .failed(errors.last ?? String(localized: "rclone exited with status \(status)."))
            }
        }
        onFinish?(self)
    }
}

/// Splits a byte stream into complete lines; thread-safe.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [line]
    }
}
