import AppKit

/// Asks before quitting while backup tasks, uploads or downloads are running, since quitting stops them.
@MainActor
enum QuitGuard {
    /// Set by the app once its state exists, so uploads and downloads can be counted too.
    static weak var model: AppModel?
    /// The user already agreed (e.g. via Restart Now), so the quit itself shouldn't ask again.
    private static var confirmed = false

    /// Stops running backups, uploads and downloads. Each runs as its own rclone process, which
    /// would otherwise keep going after the app quits, with nothing showing or tracking it.
    static func stopAll() {
        SyncManager.shared.cancelAll()
        model?.activeTransfers.forEach { $0.cancel() }
    }

    /// Returns whether quitting may go ahead, asking first if anything is still running.
    static func confirm() -> Bool {
        if confirmed { return true }
        let sync = SyncManager.shared
        let syncing = sync.tasks.filter { sync.isRunning($0.id) }.map(\.name)
        // Backup jobs are listed via SyncManager; opening or previewing a file isn't worth a prompt.
        let transfers = model?.activeTransfers.filter { $0.kind != .sync && $0.kind != .open }.count ?? 0
        guard !syncing.isEmpty || transfers > 0 else { return true }

        var lines = syncing.prefix(5).map { "• " + String(localized: "Backing up “\($0)”") }
        if syncing.count > 5 { lines.append("• " + String(localized: "\(syncing.count - 5) more backup tasks")) }
        if transfers > 0 {
            lines.append("• " + (transfers == 1 ? String(localized: "1 upload or download")
                                                : String(localized: "\(transfers) uploads or downloads")))
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Tasks are still running. Quit Rclone?")
        alert.informativeText = lines.joined(separator: "\n") + "\n\n"
            + String(localized: "Quitting stops them now. Interrupted backups can be run again later; uploads and downloads have to be started again.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        let quit = alert.addButton(withTitle: String(localized: "Quit Anyway"))
        quit.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        confirmed = true
        return true
    }
}
