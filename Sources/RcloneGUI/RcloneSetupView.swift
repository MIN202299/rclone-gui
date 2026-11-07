import AppKit
import SwiftUI

/// Shown instead of the browser when no rclone executable can be found.
struct RcloneSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var installer = RcloneInstaller()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                officialCard
                if RcloneInstaller.brewPath != nil { brewCard }
                manualCard
                status
            }
            .frame(maxWidth: 560)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .disabled(installer.isWorking)
        .task { await installer.fetchLatestVersion() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up rclone").font(.title.bold())
                Text("This app uses the free, open-source rclone tool to talk to your cloud storage. It isn't installed on this Mac yet. Pick one way to get it:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var officialCard: some View {
        SetupCard(
            symbol: "arrow.down.circle.fill",
            title: "Download rclone",
            badge: "Recommended",
            detail: "Downloads \(installer.latestVersion.map { "rclone \($0)" } ?? "the latest rclone") from rclone.org (about 33 MB), checks it against rclone's published checksum, and installs it for this app only. No administrator password needed."
        ) {
            Button("Download & Install") {
                Task { if await installer.installOfficial() { await model.loadRemotes() } }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var brewCard: some View {
        SetupCard(
            symbol: "mug.fill",
            title: "Install with Homebrew",
            badge: nil,
            detail: "Runs “brew install rclone”. rclone is then available in Terminal too, and you can update it with “brew upgrade”."
        ) {
            Button("Install with Homebrew") {
                Task { if await installer.installWithHomebrew() { await model.loadRemotes() } }
            }
        }
    }

    private var manualCard: some View {
        SetupCard(
            symbol: "folder.fill",
            title: "I already have rclone",
            badge: nil,
            detail: "If rclone is installed somewhere unusual, choose the rclone file yourself. You can change this later in Settings (⌘,)."
        ) {
            HStack {
                Button("Choose rclone…") { chooseBinary() }
                Button("Check Again") { Task { await model.loadRemotes() } }
                Spacer()
                Link("Other install options", destination: URL(string: "https://rclone.org/install/")!)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch installer.phase {
        case .idle:
            EmptyView()
        case .working(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if installer.progress == nil { ProgressView().controlSize(.small) }
                    Text(message)
                }
                if let p = installer.progress {
                    ProgressView(value: p)
                    Text(p.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                logView
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                logView
            }
        }
    }

    @ViewBuilder
    private var logView: some View {
        if !installer.log.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(installer.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 140)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
                .onChange(of: installer.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This rclone"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Rclone.pathDefaultsKey)
        Task { await model.loadRemotes() }
    }
}

private struct SetupCard<Actions: View>: View {
    let symbol: String
    let title: String
    let badge: String?
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
