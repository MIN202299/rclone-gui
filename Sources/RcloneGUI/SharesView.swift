import AppKit
import SwiftUI

/// A share being created or edited, with the secrets the editor needs.
struct ShareDraft: Identifiable {
    var share: WebDAVShare
    /// The encrypted backup's key, for a new share inside one.
    var obscuredKey: String?
    var isNew: Bool
    var id: UUID { share.id }
}

extension AppModel {
    /// A new WebDAV share for a folder on the selected remote (relative path; "" = the whole remote).
    func newShare(for relative: String) -> ShareDraft? {
        guard let remote = selectedRemoteName else { return nil }
        let crypt = cryptFolder(for: relative)
        let name = relative.split(separator: "/").last.map(String.init) ?? remote
        let share = WebDAVShare(name: name, remote: remote, path: relative,
                                encryption: crypt.map { .init(root: $0.path, encryptNames: $0.encryptNames) })
        return ShareDraft(share: share, obscuredKey: crypt?.obscuredPassword, isNew: true)
    }
}

// MARK: - Window

struct SharesView: View {
    @Environment(ShareManager.self) private var shares
    @State private var editing: ShareDraft?
    @State private var editingServer = false
    @State private var pendingDelete: WebDAVShare?

    var body: some View {
        Group {
            if shares.shares.isEmpty {
                ContentUnavailableView {
                    Label("No WebDAV Shares", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Right-click a folder and choose Share via WebDAV. Media players such as Infuse or VLC, file apps and Finder can then play and open its files over your network without downloading them first.")
                }
            } else {
                List {
                    Section {
                        ServerCard(edit: { editingServer = true })
                    }
                    Section("Shared Folders") {
                        ForEach(shares.shares) { share in
                            ShareRow(share: share,
                                     edit: { editing = ShareDraft(share: share, isNew: false) },
                                     delete: { pendingDelete = share })
                        }
                    }
                    Section {
                    } footer: {
                        Text("Shares run while Rclone is open, including when only its menu bar icon is showing. This Mac must stay awake for other devices to connect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .task { await shares.refresh() }
        .sheet(item: $editing) { ShareEditor(draft: $0) }
        .sheet(isPresented: $editingServer) { ServerEditor() }
        .confirmationDialog("Delete the share “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { share in
            Button("Delete Share", role: .destructive) { shares.delete(share.id) }
        } message: { _ in
            Text("Devices using it can no longer connect. The files on the remote are not touched.")
        }
    }
}

/// The one address, username and password that devices use for every shared folder.
private struct ServerCard: View {
    let edit: () -> Void
    @Environment(ShareManager.self) private var shares
    @State private var showPassword = false

    var body: some View {
        let status = shares.serverStatus
        let settings = shares.settings
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ShareStatusIcon(status: status)
                Text("WebDAV Server").font(.headline)
                Spacer()
                Button("Settings…", action: edit)
            }
            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                let urls = settings.urls
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    CopyableText(text: urls[0])
                }
                ForEach(urls.dropFirst(), id: \.self) { url in
                    GridRow {
                        Text(verbatim: "")
                        CopyableText(text: url, secondary: true)
                    }
                }
                GridRow {
                    Text("Username").foregroundStyle(.secondary)
                    CopyableText(text: settings.user)
                }
                GridRow {
                    Text("Password").foregroundStyle(.secondary)
                    let password = shares.password
                    HStack(spacing: 6) {
                        Text(showPassword ? password : String(repeating: "•", count: 10))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .help(showPassword ? "Hide" : "Show")
                        CopyButton(text: password)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .opacity(status == .running ? 1 : 0.6)
            Text(settings.summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct ShareRow: View {
    let share: WebDAVShare
    let edit: () -> Void
    let delete: () -> Void
    @Environment(ShareManager.self) private var shares

    var body: some View {
        let status = shares.status(share.id)
        let url = share.urls(on: shares.settings)[0]
        HStack(spacing: 8) {
            ShareStatusIcon(status: status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(share.name).font(.headline)
                    if share.encryption != nil {
                        Image(systemName: "lock.open.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Encrypted backup, shared decrypted")
                    }
                }
                Text(share.target).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if status == .running {
                    HStack(spacing: 4) {
                        Text(verbatim: url).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        CopyButton(text: url).buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            Spacer()
            Button(shares.isActive(share.id) ? "Stop" : "Start") { shares.toggle(share.id) }
            Menu {
                Button("Edit…", action: edit)
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(shares.isActive(share.id) ? "Stop" : "Start") { shares.toggle(share.id) }
            Button("Edit…", action: edit)
            Button("Copy Address") { Pasteboard.copy(url) }
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }
}

struct ShareStatusIcon: View {
    let status: ShareManager.Status

    var body: some View {
        Group {
            switch status {
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Image(systemName: "circle.fill").foregroundStyle(.green)
            case .stopped:
                Image(systemName: "circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 9))
        .frame(width: 16)
        .help(status.text)
    }
}

extension ShareManager.Status {
    var text: String {
        switch self {
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .running: return String(localized: "Running")
        case .failed: return String(localized: "Couldn't start")
        }
    }
}

private struct CopyableText: View {
    let text: String
    var secondary = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
            CopyButton(text: text)
        }
        .buttonStyle(.borderless)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .help("Copy")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Editors

struct ShareEditor: View {
    @State private var draft: ShareDraft
    @Environment(ShareManager.self) private var shares
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    init(draft: ShareDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.share.name)
                    LabeledContent("Folder") {
                        Text(draft.share.target).lineLimit(1).truncationMode(.middle)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Devices find this folder at the server's address followed by its name, and see it listed at the server's top level.")
                        if draft.share.encryption != nil {
                            Text("This folder is in an encrypted backup. Devices that connect see its files decrypted. Its key is kept in your keychain, so the share works without unlocking the folder first.")
                        }
                    }
                    .formFooter()
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Share" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 460, height: 340)
    }

    /// Why the share can't be saved as it is.
    private var problem: String? {
        let s = draft.share
        if s.serveName.isEmpty { return String(localized: "Enter a name.") }
        if let other = shares.share(named: s.name, except: s.id) {
            return String(localized: "The share “\(other.name)” already has this name.")
        }
        return nil
    }

    private func save() {
        guard problem == nil else { return }
        var share = draft.share
        share.name = share.name.trimmingCharacters(in: .whitespaces)
        shares.save(share, obscuredKey: draft.obscuredKey)
        if draft.isNew { openWindow(id: "shares") }
        dismiss()
    }
}

/// Port, sign-in and access, which all shared folders have in common.
private struct ServerEditor: View {
    @Environment(ShareManager.self) private var shares
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ShareSettings()
    @State private var password = ""
    @State private var loaded = false
    @State private var originalPort = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Read only", isOn: $settings.readOnly)
                    Toggle("Allow other devices on this network", isOn: $settings.allowNetwork)
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                } header: {
                    Text("Access")
                } footer: {
                    Text(settings.readOnly
                         ? "Devices can play, open and download files, but can't change anything."
                         : "Devices can also upload, rename and delete files in the shared folders.")
                        .formFooter()
                }
                Section {
                    TextField("Username", text: $settings.user)
                    HStack {
                        TextField("Password", text: $password)
                            .font(.body.monospaced())
                        Button("Generate") { password = ShareManager.generatePassword() }
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("Enter these in the app that connects, along with this Mac's address and the port.")
                        .formFooter()
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    settings.user = settings.user.trimmingCharacters(in: .whitespaces)
                    shares.saveSettings(settings, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 460, height: 440)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            settings = shares.settings
            originalPort = settings.port
            password = shares.password
        }
    }

    /// Why the settings can't be saved as they are.
    private var problem: String? {
        if !(1024...65535).contains(settings.port) { return String(localized: "Choose a port from 1024 to 65535.") }
        if settings.user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty {
            return String(localized: "Enter a username and password.")
        }
        // The running server holds its own port; any other taken port belongs to another app.
        let ownPort = settings.port == originalPort && shares.serverIsActive
        if !ownPort && !Network.isPortFree(settings.port) {
            return String(localized: "Port \(String(settings.port)) is already used by another app.")
        }
        return nil
    }
}
