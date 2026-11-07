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
    private static let pidKey = "rcloneDaemonPID"

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
        Self.killOrphan()
        let user = UUID().uuidString, pass = UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["rcd", "--rc-addr", "127.0.0.1:0", "--rc-user", user, "--rc-pass", pass]
        p.standardInput = FileHandle.nullDevice
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                if once.fire() {
                    p.terminate()
                    cont.resume(throwing: DaemonUnavailable(String(localized: "rclone's background service didn't start.")))
                }
            }
        }

        process = p
        baseURL = url
        launchedExe = exe
        authHeader = "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        UserDefaults.standard.set(Int(p.processIdentifier), forKey: Self.pidKey)
        return url
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
    }

    /// If the app crashed last time, its daemon may still be running.
    private static func killOrphan() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: pidKey))
        guard pid > 0, kill(pid, 0) == 0 else { return }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
              (String(cString: buf) as NSString).lastPathComponent == "rclone" else { return }
        kill(pid, SIGTERM)
    }

    // MARK: Calls

    /// POSTs a remote-control command and returns the decoded JSON object.
    func call(_ command: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let base = try await endpoint()
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
        let obj = try await call("operations/list", ["fs": "\(remote):", "remote": path, "opt": ["noMimeType": true]])
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
