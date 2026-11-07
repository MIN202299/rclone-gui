import Foundation

// MARK: - Errors

enum RcloneError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "rclone isn't installed. Open the main window to install it, or set its location in Settings (⌘,).")
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Models

struct Remote: Identifiable, Hashable {
    let name: String
    let type: String
    var id: String { name }

    var symbol: String {
        switch type {
        case "drive", "onedrive", "dropbox", "box", "pcloud", "mega", "jottacloud", "koofr", "yandex", "pikpak", "protondrive", "sharefile":
            return "cloud"
        case "s3", "b2", "azureblob", "azurefiles", "gcs", "swift", "oos", "qingstor", "storj":
            return "shippingbox"
        case "sftp", "ftp", "smb", "webdav", "http", "hdfs":
            return "server.rack"
        case "local", "alias":
            return "internaldrive"
        case "crypt":
            return "lock.shield"
        case "union", "combine", "chunker", "hasher", "compress":
            return "square.stack.3d.up"
        default:
            return "externaldrive.connected.to.line.below"
        }
    }
}

struct Entry: Identifiable, Hashable, Decodable {
    var path: String  // full path relative to the remote root (rewritten after listing)
    let name: String
    let size: Int64
    let mimeType: String?
    let modTime: Date
    let isDir: Bool

    var id: String { path }
    /// Sortable size: folders sort before every file.
    /// Folders sort first, then files of unknown size (e.g. Google Docs report -1), then by size.
    var sortSize: Int64 { isDir ? -2 : max(size, -1) }

    var sizeText: String {
        if isDir || size < 0 { return "--" }
        return size.byteString
    }

    enum CodingKeys: String, CodingKey {
        case path = "Path", name = "Name", size = "Size", mimeType = "MimeType", modTime = "ModTime", isDir = "IsDir"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        size = (try? c.decode(Int64.self, forKey: .size)) ?? -1
        mimeType = try? c.decode(String.self, forKey: .mimeType)
        isDir = (try? c.decode(Bool.self, forKey: .isDir)) ?? false
        modTime = Entry.parseDate((try? c.decode(String.self, forKey: .modTime)) ?? "")
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// rclone emits nanosecond precision, which ISO8601DateFormatter can't parse — drop the fraction.
    static func parseDate(_ string: String) -> Date {
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: stripped) ?? .distantPast
    }

    var symbol: String {
        if isDir { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return "film"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": return "music.note"
        case "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz", "dmg", "iso": return "archivebox"
        case "pdf": return "doc.richtext"
        case "txt", "md", "rtf", "log", "csv": return "doc.text"
        case "swift", "py", "js", "ts", "go", "rs", "c", "h", "cpp", "java", "json", "yaml", "yml", "html", "css", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

struct About: Decodable {
    let total: Int64?
    let used: Int64?
    let free: Int64?
    let trashed: Int64?
}

/// Backend description from `rclone config providers`.
struct Provider: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    let options: [ProviderOption]
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name = "Name", description = "Description", options = "Options" }

    static func == (a: Provider, b: Provider) -> Bool { a.name == b.name }
    func hash(into h: inout Hasher) { h.combine(name) }
}

struct ProviderOption: Decodable, Identifiable, Hashable {
    let name: String
    let help: String
    let required: Bool
    let isPassword: Bool
    let advanced: Bool
    let exclusive: Bool
    let provider: String
    let defaultString: String
    let examples: [Example]
    var id: String { name }

    struct Example: Decodable, Hashable {
        let value: String
        let help: String
        enum CodingKeys: String, CodingKey { case value = "Value", help = "Help" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? c.decode(String.self, forKey: .value)) ?? ""
            help = (try? c.decode(String.self, forKey: .help)) ?? ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name", help = "Help", required = "Required", isPassword = "IsPassword"
        case advanced = "Advanced", exclusive = "Exclusive", provider = "Provider"
        case examples = "Examples", defaultStr = "DefaultStr"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        help = (try? c.decode(String.self, forKey: .help)) ?? ""
        required = (try? c.decode(Bool.self, forKey: .required)) ?? false
        isPassword = (try? c.decode(Bool.self, forKey: .isPassword)) ?? false
        advanced = (try? c.decode(Bool.self, forKey: .advanced)) ?? false
        exclusive = (try? c.decode(Bool.self, forKey: .exclusive)) ?? false
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        defaultString = (try? c.decode(String.self, forKey: .defaultStr)) ?? ""
        examples = (try? c.decode([Example].self, forKey: .examples)) ?? []
    }

    var shortHelp: String {
        help.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// S3-style backends restrict options to particular sub-providers ("AWS,Ceph" or "!AWS").
    func applies(toProvider selected: String) -> Bool {
        guard !provider.isEmpty, !selected.isEmpty else { return true }
        let negated = provider.hasPrefix("!")
        let list = (negated ? String(provider.dropFirst()) : provider).split(separator: ",").map(String.init)
        return negated ? !list.contains(selected) : list.contains(selected)
    }
}

/// A question returned by the non-interactive `rclone config` state machine (e.g. OAuth prompts).
struct ConfigQuestion: Decodable {
    let state: String
    let option: ProviderOption?
    let error: String?

    enum CodingKeys: String, CodingKey { case state = "State", option = "Option", error = "Error" }
}

// MARK: - Runner

enum Rclone {
    static let pathDefaultsKey = "rclonePath"

    static func locate() -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: pathDefaultsKey), !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone",
            "\(home)/bin/rclone", "\(home)/.local/bin/rclone", "/opt/local/bin/rclone",
            RcloneInstaller.managedBinary.path, // installed by the in-app setup
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs rclone to completion and returns stdout. Throws with rclone's error output on failure.
    /// `input` is written to rclone's standard input (e.g. a password for `rclone obscure -`).
    static func run(_ args: [String], input: Data? = nil) async throws -> Data {
        guard let exe = locate() else { throw RcloneError.notFound }
        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if let env = rcloneEnvironment(for: args) { process.environment = env }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let inPipe = input.map { _ in Pipe() }
            process.standardInput = inPipe ?? FileHandle.nullDevice
            do { try process.run() } catch {
                cont.resume(throwing: error)
                return
            }
            if let inPipe, let input {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    cont.resume(throwing: RcloneError.failed(cleanError(errBox.data, status: process.terminationStatus)))
                }
            }
        }
    }

    static func cleanError(_ data: Data, status: Int32) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n").map(String.init)
        // Prefer real errors over NOTICE/INFO chatter.
        let serious = all.filter { $0.contains(" ERROR ") || $0.contains(" CRITICAL") || $0.hasPrefix("Error") }
        let lines = (serious.isEmpty ? all : serious).map { line -> String in
            // Strip "2024/01/01 12:00:00 ERROR : " prefixes.
            line.replacingOccurrences(
                of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} [A-Z]+\s*:\s*"#, with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? String(localized: "rclone exited with status \(status).") : tail
    }

    // MARK: Commands

    static func remotes() async throws -> [Remote] {
        let data = try await run(["listremotes", "--long"])
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[..<colon])
                let type = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return Remote(name: name, type: type)
            }
    }

    static func list(_ target: String) async throws -> [Entry] {
        let data = try await run(["lsjson", target, "--no-mimetype"])
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    static func about(_ remote: String) async throws -> About {
        let data = try await run(["about", "\(remote):", "--json"])
        return try JSONDecoder().decode(About.self, from: data)
    }

    static func providers() async throws -> [Provider] {
        let data = try await run(["config", "providers"])
        return try JSONDecoder().decode([Provider].self, from: data)
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
