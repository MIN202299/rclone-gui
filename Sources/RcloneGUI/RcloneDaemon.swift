import Darwin
import Foundation

/// A long-lived `rclone rcd` process, talked to over its HTTP remote-control API on 127.0.0.1.
///
/// Starting a new rclone per action costs ~2 s on Google Drive (login + path lookups every time).
/// The daemon keeps remotes, tokens and directory IDs warm, so listings and unchanged-file checks
/// take a fraction of a second. Callers fall back to the one-shot CLI if the daemon can't start.
@MainActor
final class RcloneDaemon {
    static let shared = RcloneDaemon()

    private var process: Process?
    private var baseURL: URL?
    private var authHeader = ""
    private var launchedExe: String?
    private var starting: Task<URL, Error>?
    /// Write end of the watchdog's stdin. It closes when this app exits for any reason (quit,
    /// `kill`, crash), and the watchdog then stops rclone.
    private var lifeline: FileHandle?
    /// Marks the rclone processes this app starts, so stale ones can be told apart from the user's own.
    private static let realm = "rclone-gui"

    /// Runs rclone as a child of a small shell that stops it as soon as its stdin reaches EOF
    /// (the app is gone) or the shell itself is told to stop. macOS has no "kill me when my
    /// parent dies" option, and rclone ignores its stdin, so the shell does the watching.
    private static let watchdog = """
        exec 3<&0
        "$0" "$@" </dev/null 3<&- &
        c=$!
        { read _ <&3; kill $c 2>/dev/null; } &
        w=$!
        exec 3<&-
        trap 'kill $c 2>/dev/null' TERM INT HUP
        wait $c
        s=$?
        wait $c 2>/dev/null
        kill $w 2>/dev/null
        exit $s
        """

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.connectionProxyDictionary = [:] // never route localhost through a system proxy
        return URLSession(configuration: config)
    }()

    // MARK: Lifecycle

    private func endpoint() async throws -> URL {
        if let process, process.isRunning, let baseURL, launchedExe == Rclone.locate() { return baseURL }
        if let starting { return try await starting.value }
        stop()
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func launch() async throws -> URL {
        guard let exe = Rclone.locate() else { throw RcloneError.notFound }
        Self.killStale()
        let user = UUID().uuidString, pass = UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.watchdog, exe, "rcd", "--rc-addr", "127.0.0.1:0",
                       "--rc-user", user, "--rc-pass", pass, "--rc-realm", Self.realm]
        let life = Pipe()
        // Keep the write end out of other processes the app starts, or they'd hold it open.
        _ = fcntl(life.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        p.standardInput = life
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err

        let url: URL = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            let log = LockedText()
            err.fileHandleForReading.readabilityHandler = { h in
                let text = log.append(String(decoding: h.availableData, as: UTF8.self))
                if let r = text.range(of: #"http://127\.0\.0\.1:\d+/"#, options: .regularExpression),
                   let u = URL(string: String(text[r])), once.fire() {
                    // Keep draining so rclone never blocks on a full pipe.
                    h.readabilityHandler = { _ = $0.availableData }
                    cont.resume(returning: u)
                }
            }
            p.terminationHandler = { proc in
                if once.fire() {
                    let text = log.text
                    cont.resume(throwing: DaemonUnavailable(Rclone.cleanError(Data(text.utf8), status: proc.terminationStatus)))
                }
            }
            do { try p.run() } catch {
                if once.fire() { cont.resume(throwing: DaemonUnavailable(error.localizedDescription)) }
                return
            }
            try? life.fileHandleForReading.close() // only the shell needs the read end
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                if once.fire() {
                    p.terminate()
                    cont.resume(throwing: DaemonUnavailable(String(localized: "rclone's background service didn't start.")))
                }
            }
        }

        lifeline = life.fileHandleForWriting
        process = p
        baseURL = url
        launchedExe = exe
        authHeader = "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        return url
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        try? lifeline?.close()
        lifeline = nil
        process = nil
        baseURL = nil
    }

    /// Stops background rclones left behind by earlier runs: ones started with this app's realm
    /// (or, from older versions, its exact random-credential arguments) whose parent is gone.
    /// A running copy of the app keeps its daemon under a live parent, so it's left alone, as are
    /// rclones the user starts themselves.
    private static func killStale() {
        UserDefaults.standard.removeObject(forKey: "rcloneDaemonPID") // used by older versions
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_ppid == 1, info.pbi_uid == getuid(),
                  let args = arguments(of: pid), isOurDaemon(args) else { continue }
            kill(pid, SIGTERM)
        }
    }

    private static func isOurDaemon(_ args: [String]) -> Bool {
        guard args.count >= 2, (args[0] as NSString).lastPathComponent == "rclone", args[1] == "rcd" else { return false }
        let rest = Array(args.dropFirst())
        if rest.suffix(2) == ["--rc-realm", realm] { return true }
        // Versions before the realm marker: rcd --rc-addr 127.0.0.1:0 --rc-user <UUID> --rc-pass <UUID>
        return rest.count == 7 && rest[1...2] == ["--rc-addr", "127.0.0.1:0"]
            && rest[3] == "--rc-user" && UUID(uuidString: rest[4]) != nil
            && rest[5] == "--rc-pass" && UUID(uuidString: rest[6]) != nil
    }

    /// A process's argv, read via sysctl (only works for the current user's processes).
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 } // executable path
        while i < size, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    // MARK: Calls

    /// POSTs a remote-control command and returns the decoded JSON object.
    func call(_ command: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let base = try await endpoint()
        var params = params
        // Encrypted folders are named by an alias ("rgcrypt_…:"), defined for one-shot processes through
        // environment variables; the background rclone gets the full definition instead.
        for key in ["fs", "srcFs", "dstFs"] {
            if let fs = params[key] as? String { params[key] = CryptAliases.shared.daemonFs(fs) }
        }
        var req = URLRequest(url: base.appendingPathComponent(command))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (obj["error"] as? String) ?? String(decoding: data, as: UTF8.self)
            throw RcloneError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return obj
    }

    // MARK: Operations

    func list(remote: String, path: String) async throws -> [Entry] {
        try await list(fs: "\(remote):", path: path)
    }

    func list(fs: String, path: String) async throws -> [Entry] {
        let obj = try await call("operations/list", ["fs": fs, "remote": path, "opt": ["noMimeType": true]])
        let items = obj["list"] as? [Any] ?? []
        let data = try JSONSerialization.data(withJSONObject: items)
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    func about(remote: String) async throws -> About {
        let obj = try await call("operations/about", ["fs": "\(remote):"])
        return try JSONDecoder().decode(About.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    /// Whether the remote can't keep modification times (e.g. some WebDAV servers). rclone then
    /// compares files by size alone, and the times it lists may change without the file changing.
    func modTimeUnsupported(remote: String) async throws -> Bool {
        let obj = try await call("operations/fsinfo", ["fs": "\(remote):"])
        let precision = (obj["Precision"] as? NSNumber)?.int64Value ?? 0
        return precision >= 3_153_600_000_000_000_000 // rclone's ModTimeNotSupported: 100 years in ns
    }
}

private final class LockedText: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()
    func append(_ s: String) -> String { lock.lock(); defer { lock.unlock() }; value += s; return value }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// The background rclone couldn't be started or reached; callers should fall back to the CLI.
struct DaemonUnavailable: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func matches(_ error: Error) -> Bool { error is DaemonUnavailable || error is URLError }
}

/// Thread-safe "first caller wins" flag.
private final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
