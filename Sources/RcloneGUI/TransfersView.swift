import AppKit
import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { model.clearFinishedTransfers() }
                    .disabled(model.transfers.allSatisfy(\.isRunning))
            }
            .padding(12)
            Divider()
            if model.transfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Uploads and downloads appear here."))
                    .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.transfers) { transfer in
                            TransferRow(transfer: transfer)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 400)
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transfer.symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title).lineLimit(1).truncationMode(.middle)
                Text(transfer.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if transfer.isRunning {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(transfer.statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if transfer.isRunning {
                Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            } else if transfer.state == .done, let url = transfer.localURL, (transfer.kind == .download || transfer.kind == .sync) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var tint: Color {
        switch transfer.state {
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
