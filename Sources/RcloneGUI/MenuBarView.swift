import AppKit
import SwiftUI

/// Menu bar icon: a plain cloud; it switches to a sync cloud while jobs run.
/// Progress details live in the panel that opens on click.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.activeTransfers.isEmpty ? "icloud" : "arrow.triangle.2.circlepath.icloud")
            .onAppear {
                MainWindow.open = { openWindow(id: "main") }
                MainWindow.openSync = { openWindow(id: "sync"); NSApp.activate(ignoringOtherApps: true) }
            }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncManager.self) private var sync
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            if !sync.tasks.isEmpty {
                syncSection
                Divider()
            }
            if model.transfers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.icloud").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Everything is up to date").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.transfers.prefix(20)) { transfer in
                            TransferRow(transfer: transfer)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            Divider()
            HStack {
                Button("Open Rclone") { MainWindow.show() }
                Spacer()
                Button("Clear Finished") { model.clearFinishedTransfers() }
                    .disabled(model.transfers.allSatisfy(\.isRunning))
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 360)
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Backup Tasks").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Manage…") { MainWindow.openSync?() }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(sync.tasks.prefix(6)) { task in
                HStack(spacing: 8) {
                    Image(systemName: task.mode.symbol)
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, isActive: sync.isRunning(task.id))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.name).lineLimit(1)
                        SyncStatusLine(task: task).font(.caption2)
                    }
                    Spacer(minLength: 4)
                    if sync.isRunning(task.id) {
                        Button { sync.cancel(task.id) } label: { Image(systemName: "stop.circle") }
                            .help("Stop")
                    } else {
                        Button { sync.run(task.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                            .help("Back Up Now")
                            .disabled(task.paused)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
    }

    private var header: some View {
        let active = model.activeTransfers
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Rclone").font(.headline)
                Spacer()
                Text(active.isEmpty ? "Idle" : active.count == 1 ? "1 job running" : "\(active.count) jobs running")
                    .foregroundStyle(.secondary)
            }
            if !active.isEmpty {
                if let p = model.overallProgress {
                    ProgressView(value: p)
                    HStack {
                        Text(model.overallBytesText)
                        Spacer()
                        Text(p.formatted(.percent.precision(.fractionLength(0))))
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }
}
