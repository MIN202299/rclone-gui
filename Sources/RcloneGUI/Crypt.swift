import Foundation
import Security

// MARK: - Marker

/// Plain-text settings file kept in the folder of an encrypted backup, so the app can tell the folder
/// is encrypted and check a password before using it. It never contains the password.
///
/// The backup itself is an ordinary rclone `crypt` folder (password only, rclone's default salt), so
/// `rclone` on its own can read it with the same password. rclone skips this file when it lists the
/// folder through crypt, because its name isn't an encrypted name.
struct CryptMarker: Codable, Equatable {
    static let fileName = ".rclonegui-crypt.json"
    /// Encrypted with standard name encryption to make `check`; the result depends only on the password.
    static let checkPlaintext = "rclonegui-check"

    var format = 1
    /// Whether file and folder names are encrypted too (rclone `filename_encryption = standard`),
    /// or only file contents (`off`, names stay readable and get a ".bin" suffix).
    var encryptNames: Bool
    /// `checkPlaintext` as an encrypted name; the same password always gives the same value.
    var check: String
    var created: Date?
}

// MARK: - Folder

/// An encrypted backup folder that can be read and written through rclone `crypt`.
struct CryptFolder: Hashable {
    /// The plain remote and the folder on it that holds the encrypted files.
    let remote: String
    let path: String
    let encryptNames: Bool
    /// rclone-obscured password (reversible, so it's only ever kept in memory).
    let obscuredPassword: String

    var plainTarget: String { "\(remote):\(path)" }

    /// A short name for this folder's crypt remote, defined through environment variables for
    /// one-shot rclone processes, so the password never appears in a process's arguments.
    var alias: String {
        var h = StableHasher()
        h.combine(plainTarget); h.combine(obscuredPassword); h.combine(encryptNames ? "1" : "0")
        return "rgcrypt_\(h.hex)"
    }

    /// The same crypt remote as an rclone connection string, for the background rclone (whose
    /// environment is fixed when it starts). Only ever sent over its local HTTP connection.
    var connectionString: String {
        Crypt.connectionString(base: plainTarget, obscured: obscuredPassword, encryptNames: encryptNames)
    }

    var environment: [String: String] {
        let key = "RCLONE_CONFIG_\(alias.uppercased())_"
        return [
            key + "TYPE": "crypt",
            key + "REMOTE": plainTarget,
            key + "PASSWORD": obscuredPassword,
            key + "FILENAME_ENCRYPTION": encryptNames ? "standard" : "off",
            key + "DIRECTORY_NAME_ENCRYPTION": encryptNames ? "true" : "false",
        ]
    }
}

// MARK: - Aliases

/// Crypt remotes currently in use, so any rclone process whose arguments name one gets the
/// environment variables that define it.
final class CryptAliases: @unchecked Sendable {
    static let shared = CryptAliases()
    private var folders: [String: CryptFolder] = [:]
    private var uses: [String: Int] = [:]
    private let lock = NSLock()

    func register(_ folder: CryptFolder) {
        lock.lock(); defer { lock.unlock() }
        folders[folder.alias] = folder
        uses[folder.alias, default: 0] += 1
    }

    func unregister(_ folder: CryptFolder) {
        lock.lock(); defer { lock.unlock() }
        let n = (uses[folder.alias] ?? 1) - 1
        if n <= 0 { uses[folder.alias] = nil; folders[folder.alias] = nil } else { uses[folder.alias] = n }
    }

    func folder(alias: String) -> CryptFolder? {
        lock.lock(); defer { lock.unlock() }
        return folders[alias]
    }

    /// The environment to add for a process run with `args`.
    func environment(for args: [String]) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var env: [String: String] = [:]
        for (alias, folder) in folders where args.contains(where: { $0.hasPrefix(alias + ":") }) {
            env.merge(folder.environment) { a, _ in a }
        }
        return env
    }

    /// Turns "rgcrypt_…:path" into the fs string the background rclone understands.
    func daemonFs(_ fs: String) -> String {
        guard fs.hasPrefix("rgcrypt_"), let colon = fs.firstIndex(of: ":"),
              let folder = folder(alias: String(fs[..<colon])) else { return fs }
        let rest = fs[fs.index(after: colon)...]
        return folder.connectionString + rest
    }
}

/// Process environment with the crypt remotes `args` refer to.
func rcloneEnvironment(for args: [String]) -> [String: String]? {
    let extra = CryptAliases.shared.environment(for: args)
    guard !extra.isEmpty else { return nil }
    return ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
}

// MARK: - Operations

enum CryptError: LocalizedError {
    case wrongPassword
    case noPassword
    case notEmpty(String)
    case notEncrypted(String)
    case isEncrypted(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return String(localized: "The password is wrong for this encrypted backup.")
        case .noPassword:
            return String(localized: "No password is saved for this encrypted backup. Edit the task and enter it again.")
        case .notEmpty(let target):
            return String(localized: "“\(target)” already has files that aren't part of an encrypted backup. Choose a new or empty folder for an encrypted backup.")
        case .notEncrypted(let target):
            return String(localized: "“\(target)” doesn't hold an encrypted backup.")
        case .isEncrypted(let target):
            return String(localized: "“\(target)” holds an encrypted backup. Turn on encryption for this task to use it.")
        }
    }
}

@MainActor
enum Crypt {
    /// rclone's connection-string quoting: wrap in single quotes, doubling any inside.
    nonisolated static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    nonisolated static func connectionString(base: String, obscured: String, encryptNames: Bool) -> String {
        ":crypt,remote=\(quote(base)),password=\(quote(obscured))"
            + ",filename_encryption=\(encryptNames ? "standard" : "off")"
            + ",directory_name_encryption=\(encryptNames ? "true" : "false"):"
    }

    /// rclone's reversible "obscure" encoding, which crypt expects for passwords in its settings.
    static func obscure(_ password: String) async throws -> String {
        do {
            let r = try await RcloneDaemon.shared.call("core/obscure", ["clear": password])
            if let s = r["obscured"] as? String { return s }
            throw RcloneError.failed(String(localized: "rclone couldn't encode the password."))
        } catch where DaemonUnavailable.matches(error) {
            // Read the password from standard input so it never shows up in the process list.
            let out = try await Rclone.run(["obscure", "-"], input: Data(password.utf8))
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `checkPlaintext` encrypted with this password (names always encrypted, whatever the folder uses).
    static func checkValue(obscured: String) async throws -> String {
        // The base doesn't matter: name encryption depends only on the password.
        let fs = connectionString(base: NSTemporaryDirectory(), obscured: obscured, encryptNames: true)
        do {
            let r = try await RcloneDaemon.shared.call("backend/command",
                                                       ["command": "encode", "fs": fs, "arg": [CryptMarker.checkPlaintext]])
            if let s = (r["result"] as? [Any])?.first as? String { return s }
            throw RcloneError.failed(String(localized: "rclone couldn't check the password."))
        } catch where DaemonUnavailable.matches(error) {
            let folder = CryptFolder(remote: "local", path: NSTemporaryDirectory(), encryptNames: true, obscuredPassword: obscured)
            CryptAliases.shared.register(folder)
            defer { CryptAliases.shared.unregister(folder) }
            let out = try await Rclone.run(["backend", "encode", "\(folder.alias):", CryptMarker.checkPlaintext])
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Opens an encrypted folder with `password`, or throws `CryptError.wrongPassword`.
    static func open(remote: String, path: String, marker: CryptMarker, password: String) async throws -> CryptFolder {
        let obscured = try await obscure(password)
        guard try await checkValue(obscured: obscured) == marker.check else { throw CryptError.wrongPassword }
        return CryptFolder(remote: remote, path: path, encryptNames: marker.encryptNames, obscuredPassword: obscured)
    }

    /// The marker in a remote folder, or nil if the folder isn't an encrypted backup (or doesn't exist).
    static func readMarker(remote: String, path: String) async throws -> CryptMarker? {
        let file = AppModel.join(path, CryptMarker.fileName)
        let data: Data
        do {
            let stat = try await RcloneDaemon.shared.call("operations/stat", ["fs": "\(remote):", "remote": file])
            guard stat["item"] is [String: Any] else { return nil }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RcloneGUI-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            _ = try await RcloneDaemon.shared.call("operations/copyfile", [
                "srcFs": "\(remote):", "srcRemote": file, "dstFs": tmp.path, "dstRemote": CryptMarker.fileName,
            ])
            data = try Data(contentsOf: tmp.appendingPathComponent(CryptMarker.fileName))
        } catch where DaemonUnavailable.matches(error) {
            let listing = try? await Rclone.run(["lsf", "\(remote):\(path)", "--files-only", "--include", "/" + CryptMarker.fileName])
            guard let listing, !listing.isEmpty else { return nil }
            data = try await Rclone.run(["cat", "\(remote):\(file)"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CryptMarker.self, from: data)
    }

    static func writeMarker(_ marker: CryptMarker, remote: String, path: String) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RcloneGUI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try encoder.encode(marker).write(to: tmp.appendingPathComponent(CryptMarker.fileName))
        let file = AppModel.join(path, CryptMarker.fileName)
        do {
            _ = try await RcloneDaemon.shared.call("operations/copyfile", [
                "srcFs": tmp.path, "srcRemote": CryptMarker.fileName, "dstFs": "\(remote):", "dstRemote": file,
            ])
        } catch where DaemonUnavailable.matches(error) {
            _ = try await Rclone.run(["copyto", tmp.appendingPathComponent(CryptMarker.fileName).path, "\(remote):\(file)"])
        }
    }

    /// Whether a remote folder is missing or has nothing in it.
    static func isEmptyOrMissing(remote: String, path: String) async throws -> Bool {
        do {
            let items = try await RcloneDaemon.shared.list(remote: remote, path: path)
            return items.isEmpty
        } catch where DaemonUnavailable.matches(error) {
            let items = try? await Rclone.list("\(remote):\(path)")
            return items?.isEmpty ?? true
        } catch {
            if "\(error)".localizedCaseInsensitiveContains("not found") { return true }
            throw error
        }
    }

    /// Makes the background rclone forget crypt remotes it has open (and their keys).
    static func forgetOpenFolders() async {
        _ = try? await RcloneDaemon.shared.call("fscache/clear")
    }
}

// MARK: - Keychain

/// Passwords of encrypted backups, kept in the login keychain.
enum CryptKeychain {
    private static let service = "Rclone GUI encrypted backup"

    static func taskAccount(_ id: UUID) -> String { "task:\(id.uuidString)" }
    static func folderAccount(_ plainTarget: String) -> String { "folder:\(plainTarget)" }

    static func password(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String, _ account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Stable hash

/// FNV-1a: unlike `Hasher`, the same input gives the same value in every launch.
struct StableHasher {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func combine(_ s: String) {
        for b in s.utf8 { value = (value ^ UInt64(b)) &* 0x100_0000_01b3 }
        value = (value ^ 0xff) &* 0x100_0000_01b3
    }
    var hex: String { String(value, radix: 16) }
}
