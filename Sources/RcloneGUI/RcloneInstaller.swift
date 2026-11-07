import CryptoKit
import Foundation
import Observation

/// Installs rclone when it's missing: either the official build from rclone.org (verified
/// against rclone's SHA256SUMS, installed just for this app, no admin rights) or via Homebrew.
@Observable @MainActor
final class RcloneInstaller {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    var phase: Phase = .idle
    var progress: Double?
    var log = ""
    var latestVersion: String?

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// Where the app-managed copy lives: ~/Library/Application Support/RcloneGUI/bin/rclone
    nonisolated static var managedBinary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RcloneGUI/bin/rclone")
    }

    nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let base = URL(string: "https://downloads.rclone.org")!
    #if arch(arm64)
    private static let platform = "osx-arm64"
    #else
    private static let platform = "osx-amd64"
    #endif

    @ObservationIgnored private var observation: NSKeyValueObservation?

    func fetchLatestVersion() async {
        guard latestVersion == nil else { return }
        latestVersion = try? await Self.currentVersion()
    }

    private static func currentVersion() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("version.txt"))
        // "rclone v1.76.0"
        guard let v = String(decoding: data, as: UTF8.self).split(separator: " ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines), v.hasPrefix("v") else {
            throw InstallError(String(localized: "Couldn't read the latest rclone version from rclone.org."))
        }
        return v
    }

    // MARK: Official download

    func installOfficial() async -> Bool {
        progress = nil
        log = ""
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("rclone-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            phase = .working(String(localized: "Checking the latest version…"))
            let version = try await Self.currentVersion()
            latestVersion = version
            let zipName = "rclone-\(version)-\(Self.platform).zip"
            let folder = Self.base.appendingPathComponent(version)

            phase = .working(String(localized: "Fetching checksums…"))
            let (sumsData, _) = try await URLSession.shared.data(from: folder.appendingPathComponent("SHA256SUMS"))
            guard let expected = String(decoding: sumsData, as: UTF8.self)
                .split(separator: "\n")
                .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
                .first(where: { $0.count == 2 && $0[1] == zipName })?[0] else {
                throw InstallError(String(localized: "rclone.org has no checksum for \(zipName)."))
            }

            phase = .working(String(localized: "Downloading rclone \(version)…"))
            progress = 0
            let zip = work.appendingPathComponent(zipName)
            try await download(folder.appendingPathComponent(zipName), to: zip)
            progress = nil

            phase = .working(String(localized: "Verifying download…"))
            let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else {
                throw InstallError(String(localized: "The download didn't match rclone's published checksum, so it was discarded. Please try again."))
            }

            phase = .working(String(localized: "Installing…"))
            let unzipped = work.appendingPathComponent("unzipped")
            try await runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            guard let binary = fm.enumerator(at: unzipped, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "rclone" }) else {
                throw InstallError(String(localized: "The rclone archive didn't contain the rclone program."))
            }
            let dest = Self.managedBinary
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: binary, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            removexattr(dest.path, "com.apple.quarantine", 0)

            let output = try await runTool(dest.path, ["version"])
            finishInstall(String(output.split(separator: "\n").first ?? "rclone"))
            return true
        } catch {
            progress = nil
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: InstallError(String(localized: "Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in self?.progress = value }
            }
            task.resume()
        }
        observation = nil
    }

    // MARK: Homebrew

    func installWithHomebrew() async -> Bool {
        guard let brew = Self.brewPath else {
            phase = .failed(String(localized: "Homebrew isn't installed."))
            return false
        }
        progress = nil
        log = "$ brew install rclone\n"
        phase = .working(String(localized: "Installing with Homebrew… this can take a few minutes."))
        do {
            try await runTool(brew, ["install", "rclone"], streamLog: true)
            let path = (brew as NSString).deletingLastPathComponent + "/rclone"
            let output = try await runTool(path, ["version"])
            finishInstall(String(output.split(separator: "\n").first ?? "rclone"))
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func finishInstall(_ versionLine: String) {
        // A stale custom path would hide the new install.
        if let custom = UserDefaults.standard.string(forKey: Rclone.pathDefaultsKey), !custom.isEmpty,
           !FileManager.default.isExecutableFile(atPath: custom) {
            UserDefaults.standard.removeObject(forKey: Rclone.pathDefaultsKey)
        }
        phase = .done(String(localized: "Installed \(versionLine)."))
    }

    // MARK: Process helper

    @discardableResult
    private func runTool(_ exe: String, _ args: [String], streamLog: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_COLOR"] = "1"
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let collected = OutputBox()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                let text = String(decoding: d, as: UTF8.self)
                collected.append(text)
                if streamLog { Task { @MainActor in self?.log += text } }
            }
            p.terminationHandler = { [weak self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                collected.append(rest)
                if streamLog, !rest.isEmpty { Task { @MainActor in self?.log += rest } }
                if proc.terminationStatus == 0 {
                    cont.resume(returning: collected.text)
                } else {
                    let tail = collected.text.split(separator: "\n").suffix(3).joined(separator: "\n")
                    cont.resume(throwing: InstallError(tail.isEmpty ? String(localized: "\(exe) failed (\(proc.terminationStatus)).") : tail))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class OutputBox: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}
