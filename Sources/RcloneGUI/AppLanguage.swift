import AppKit
import Foundation

/// The app's display language. "System" follows macOS (System Settings → General → Language & Region,
/// where Rclone can also be set per app); the others override it for this app only.
/// macOS picks the language at launch, so a change applies after restarting.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Shown in the picker. Language names are written in their own language, so people can
    /// find theirs even when the app is in a language they can't read.
    var displayName: String {
        switch self {
        case .system: return String(localized: "System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    private static let key = "AppleLanguages"

    /// The override saved for this app (not the system-wide list macOS also reports under this key).
    static var current: AppLanguage {
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        guard let first = saved?.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Whether the app runs from an .app bundle, so it can relaunch itself.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens the app again once this process has exited.
    @MainActor
    static func relaunch() {
        guard canRelaunch else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
