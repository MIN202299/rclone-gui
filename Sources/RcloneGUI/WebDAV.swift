import Darwin
import Foundation
import Observation
import SystemConfiguration

/// A remote folder shared over WebDAV by the background rclone, so media players (Infuse, VLC…),
/// file apps and Finder can read its files on demand instead of downloading them first.
/// Inside an unlocked encrypted backup the files are served decrypted.
///
/// All shares are served by one WebDAV server on one port: each is a folder at the top level of it.
struct WebDAVShare: Codable, Identifiable, Hashable {
    /// The encrypted backup the shared folder is in. Its key (rclone-obscured password) is kept in
    /// the keychain, so the share can start without the folder being unlocked in the browser.
    struct Encryption: Codable, Hashable {
        /// The backup's folder on the remote (the one holding the marker file).
        var root: String
        var encryptNames: Bool
    }

    var id = UUID()
    /// Also the folder's name in the server (its address is the server's, followed by `/name`).
    var name: String
    var remote: String
    /// The shared folder, relative to the remote root (plain path, never a crypt alias).
    var path: String
    var encryption: Encryption?
    /// Whether the folder is currently shared. Shared folders are shared again when Rclone opens.
    var enabled = true

    var target: String { "\(remote):\(path)" }

    /// The folder's name as it appears in the server (no characters rclone or URLs trip over).
    var serveName: String {
        name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "=", with: "-")
    }

    init(name: String, remote: String, path: String, encryption: Encryption? = nil) {
        self.name = name
        self.remote = remote
        self.path = path
        self.encryption = encryption
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, remote, path, encryption, enabled
        case startAutomatically // from when every share had its own server
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        remote = try c.decode(String.self, forKey: .remote)
        path = try c.decode(String.self, forKey: .path)
        encryption = try c.decodeIfPresent(Encryption.self, forKey: .encryption)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .startAutomatically) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(remote, forKey: .remote)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(encryption, forKey: .encryption)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// How the one WebDAV server is reached. The password is kept in the keychain.
struct ShareSettings: Codable, Equatable {
    var port = 8080
    var user = "rclone"
    /// Clients can only read; they can't upload, rename or delete.
    var readOnly = true
    /// Other devices on the network can connect; otherwise only this Mac.
    var allowNetwork = true

    /// Where rclone listens: every interface, or loopback only.
    var bindAddress: String { allowNetwork ? ":\(port)" : "127.0.0.1:\(port)" }

    /// URLs of the server, the most useful first.
    var urls: [String] {
        guard allowNetwork else { return ["http://localhost:\(port)"] }
        var hosts = Network.ipv4Addresses()
        if let name = Network.localHostName() { hosts.append(name) }
        if hosts.isEmpty { hosts = ["localhost"] }
        return hosts.map { "http://\($0):\(port)" }
    }

    /// "Read only · Other devices on this network".
    var summary: String {
        [readOnly ? String(localized: "Read only") : String(localized: "Read and write"),
         allowNetwork ? String(localized: "Other devices on this network") : String(localized: "This Mac only")]
            .joined(separator: " · ")
    }
}

extension WebDAVShare {
    /// URLs of this folder: the server's, followed by the folder's name.
    func urls(on settings: ShareSettings) -> [String] {
        let encoded = serveName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serveName
        return settings.urls.map { "\($0)/\(encoded)" }
    }
}

/// Starts, stops and remembers the WebDAV shares. They run as one server inside the background
/// rclone (`serve/start` over a `combine` remote), so it stops whenever the app goes away, along
/// with the rclone itself.
@Observable @MainActor
final class ShareManager {
    static let shared = ShareManager()

    enum Status: Equatable {
        case stopped, starting, running
        case failed(String)
    }

    private(set) var shares: [WebDAVShare] = []
    private(set) var settings = ShareSettings()
    /// The state of the server (stopped while no folder is shared).
    private(set) var serverStatus: Status = .stopped
    /// rclone's id for the running server, and what it was started with.
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private var runningSignature: String?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var dirty = false

    private static let keychain = Keychain(service: "Rclone GUI WebDAV share")
    private static let serverPasswordAccount = "pass:server"
    private static var storeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RcloneGUI", isDirectory: true)
    }
    private static var storeURL: URL { storeDirectory.appendingPathComponent("webdav-shares.json") }
    private static var settingsURL: URL { storeDirectory.appendingPathComponent("webdav-server.json") }

    private init() {
        load()
        // A new background rclone (e.g. after choosing another rclone in Settings) has none of the
        // servers the old one ran, so start it again there.
        RcloneDaemon.shared.onRestart = { [weak self] in self?.daemonRestarted() }
        Task { self.apply() }
    }

    // MARK: Queries

    var enabledShares: [WebDAVShare] { shares.filter(\.enabled) }
    var password: String { Self.keychain.password(Self.serverPasswordAccount) ?? "" }

    func status(_ id: UUID) -> Status {
        shares.first { $0.id == id }?.enabled == true ? serverStatus : .stopped
    }
    func isRunning(_ id: UUID) -> Bool { status(id) == .running }
    func isActive(_ id: UUID) -> Bool { shares.first { $0.id == id }?.enabled == true }
    var serverIsActive: Bool { serverStatus == .running || serverStatus == .starting }

    /// A free port: 8080 and up, skipping ones other apps use.
    static func suggestedPort() -> Int {
        (8080...8180).first { Network.isPortFree($0) } ?? 8080
    }

    /// The share named like `name` other than `id`, if any (names are the folders' names in the server).
    func share(named name: String, except id: UUID) -> WebDAVShare? {
        let key = WebDAVShare(name: name, remote: "", path: "").serveName.lowercased()
        return shares.first { $0.id != id && $0.serveName.lowercased() == key }
    }

    static func generatePassword() -> String {
        // No look-alike characters, so it's easy to type on a TV remote.
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }

    // MARK: Editing

    /// Adds or updates a share. `obscuredKey` is the encrypted backup's key, for a new encrypted share.
    func save(_ share: WebDAVShare, obscuredKey: String? = nil) {
        if let obscuredKey { Self.keychain.setPassword(obscuredKey, "key:\(share.id.uuidString)") }
        if let i = shares.firstIndex(where: { $0.id == share.id }) { shares[i] = share } else { shares.append(share) }
        persist()
        apply()
    }

    func delete(_ id: UUID) {
        shares.removeAll { $0.id == id }
        Self.keychain.delete("key:\(id.uuidString)")
        persist()
        apply()
    }

    func saveSettings(_ new: ShareSettings, password: String) {
        Self.keychain.setPassword(password, Self.serverPasswordAccount)
        settings = new
        persistSettings()
        apply()
    }

    // MARK: Running

    func start(_ id: UUID) { setEnabled(id, true) }
    func stop(_ id: UUID) { setEnabled(id, false) }
    func toggle(_ id: UUID) { setEnabled(id, !isActive(id)) }

    private func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = shares.firstIndex(where: { $0.id == id }), shares[i].enabled != enabled else { return }
        shares[i].enabled = enabled
        persist()
        apply()
    }

    /// Makes the running server match the shared folders and settings: starts, restarts or stops it.
    private func apply() {
        dirty = true
        guard !applying else { return }
        applying = true
        Task {
            while dirty {
                dirty = false
                await applyOnce()
            }
            applying = false
        }
    }

    private func applyOnce() async {
        let wanted: (params: [String: Any], signature: String)?
        do {
            wanted = try serverParameters()
        } catch {
            await stopServer()
            serverStatus = .failed(error.localizedDescription)
            return
        }
        if wanted?.signature == runningSignature, serverID != nil || wanted == nil { return }
        await stopServer()
        guard let wanted else { return }
        serverStatus = .starting
        do {
            let result = try await RcloneDaemon.shared.call("serve/start", wanted.params)
            let id = result["id"] as? String
            guard !dirty else {
                // Changed again while starting: stop this one, the next round starts the right one.
                if let id { _ = try? await RcloneDaemon.shared.call("serve/stop", ["id": id]) }
                return
            }
            serverID = id
            runningSignature = wanted.signature
            serverStatus = .running
        } catch {
            serverStatus = .failed(Self.describe(error, port: settings.port))
        }
    }

    private func stopServer() async {
        let id = serverID
        serverID = nil
        runningSignature = nil
        serverStatus = .stopped
        if let id { _ = try? await RcloneDaemon.shared.call("serve/stop", ["id": id]) }
    }

    /// Checks that the server believed to be running still is (the background rclone may have
    /// stopped), and starts it again if not.
    func refresh() async {
        guard let id = serverID, let result = try? await RcloneDaemon.shared.call("serve/list") else { return }
        let alive = Set((result["list"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        guard !alive.contains(id), serverID == id else { return }
        serverID = nil
        runningSignature = nil
        serverStatus = .stopped
        apply()
    }

    private func daemonRestarted() {
        serverID = nil
        runningSignature = nil
        serverStatus = .stopped
        apply()
    }

    /// What to ask rclone for: one WebDAV server over all shared folders. Nil when none is shared.
    private func serverParameters() throws -> (params: [String: Any], signature: String)? {
        let active = enabledShares
        guard !active.isEmpty else { return nil }
        let upstreams = try active.map { "\"" + (try upstream(for: $0).replacingOccurrences(of: "\"", with: "\"\"")) + "\"" }
        var params: [String: Any] = [
            "type": "webdav",
            "fs": ":combine,upstreams=\(Crypt.quote(upstreams.joined(separator: " "))):",
            "addr": settings.bindAddress,
            "read_only": settings.readOnly ? "true" : "false",
        ]
        let password = self.password
        if !settings.user.isEmpty && !password.isEmpty {
            params["user"] = settings.user
            params["pass"] = password
        }
        if active.contains(where: { $0.encryption != nil }) {
            // Decrypted files would land in rclone's cache, outside this app's control: stream
            // everything instead (only files being uploaded are cached, while they're written).
            params["vfs_cache_mode"] = "minimal"
        } else {
            // Keep what players read on disk for a while, so seeking and replays are quick.
            params["vfs_cache_mode"] = "full"
            params["vfs_cache_max_size"] = "10G"
            params["vfs_cache_max_age"] = "24h"
        }
        let signature = params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: "\n")
        return (params, signature)
    }

    /// One entry of the combined remote: the folder's name, then the plain folder, or the folder
    /// decrypted through crypt.
    private func upstream(for share: WebDAVShare) throws -> String {
        guard let enc = share.encryption else { return "\(share.serveName)=\(share.target)" }
        guard let key = Self.keychain.password("key:\(share.id.uuidString)") else {
            throw RcloneError.failed(String(localized: "The key of the encrypted backup of “\(share.name)” is missing. Unlock the folder and share it again."))
        }
        let base = Crypt.connectionString(base: "\(share.remote):\(enc.root)", obscured: key, encryptNames: enc.encryptNames)
        return "\(share.serveName)=" + base + AppModel.subpath(share.path, of: enc.root)
    }

    private static func describe(_ error: Error, port: Int) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("address already in use") {
            return String(localized: "Port \(String(port)) is already used by another app. Choose another port in the server settings.")
        }
        // Errors can quote an encrypted folder's settings, key included.
        return text.replacingOccurrences(of: "password='+[^']*'+", with: "password=…", options: .regularExpression)
    }

    // MARK: Persistence

    /// The settings every share had of its own before they were served together.
    private struct LegacyShare: Decodable {
        var id: UUID
        var port: Int?
        var user: String?
        var readOnly: Bool?
        var allowNetwork: Bool?
    }

    private func load() {
        shares = (try? JSONDecoder().decode([WebDAVShare].self, from: Data(contentsOf: Self.storeURL))) ?? []
        // Folders are now told apart by name, so give clashing ones their own.
        var seen = Set<String>()
        for i in shares.indices {
            var name = shares[i].name
            var n = 2
            while !seen.insert(shares[i].serveName(replacing: name).lowercased()).inserted {
                name = "\(shares[i].name) \(n)"
                n += 1
            }
            shares[i].name = name
        }
        if let data = try? Data(contentsOf: Self.settingsURL),
           let saved = try? JSONDecoder().decode(ShareSettings.self, from: data) {
            settings = saved
            return
        }
        // First run of the combined server: carry over the first share's settings.
        let legacy = (try? JSONDecoder().decode([LegacyShare].self, from: Data(contentsOf: Self.storeURL))) ?? []
        if let first = legacy.first {
            settings = ShareSettings(port: first.port ?? 8080, user: first.user ?? "rclone",
                                     readOnly: legacy.allSatisfy { $0.readOnly ?? true },
                                     allowNetwork: legacy.contains { $0.allowNetwork ?? true })
            if let old = Self.keychain.password("pass:\(first.id.uuidString)") {
                Self.keychain.setPassword(old, Self.serverPasswordAccount)
            }
            for share in legacy { Self.keychain.delete("pass:\(share.id.uuidString)") }
        } else {
            settings.port = Self.suggestedPort()
        }
        if Self.keychain.password(Self.serverPasswordAccount) == nil {
            Self.keychain.setPassword(Self.generatePassword(), Self.serverPasswordAccount)
        }
        persistSettings()
        persist()
    }

    private func persist() { write(shares, to: Self.storeURL) }
    private func persistSettings() { write(settings, to: Self.settingsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private extension WebDAVShare {
    func serveName(replacing name: String) -> String {
        var copy = self
        copy.name = name
        return copy.serveName
    }
}

// MARK: - Network

// MARK: - Network

enum Network {
    /// This Mac's IPv4 addresses on its network interfaces (Wi-Fi and Ethernet first), without
    /// loopback and self-assigned ones.
    static func ipv4Addresses() -> [String] {
        var found: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            found.append((String(cString: ifa.ifa_name), address))
        }
        let rank = { (name: String) in name.hasPrefix("en") ? 0 : name.hasPrefix("bridge") ? 2 : 1 }
        var seen = Set<String>()
        return found.sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
            .map(\.address).filter { seen.insert($0).inserted }
    }

    /// The Bonjour name, e.g. "Duans-MacBook.local".
    static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// Whether nothing is listening on `port` (tries to bind it without listening).
    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
