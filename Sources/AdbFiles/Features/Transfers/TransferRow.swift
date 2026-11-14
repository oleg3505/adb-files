import AppKit
import SwiftUI

/// One transfer: name, progress bar, status line and Cancel / Retry / Show in Finder.
struct TransferRow: View {
    let item: TransferItem
    let queue: TransferQueue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.request.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.state == .running || item.state == .preparing {
                    ProgressView(value: item.fractionDone)
                        .progressViewStyle(.linear)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.request.direction == .download ? "Download" : "Upload") \(item.name), \(status)")
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .queued, .preparing, .running:
            Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel")
                .accessibilityLabel("Cancel")
        case .failed(_, true), .cancelled:
            Button { queue.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
                .help("Retry")
                .accessibilityLabel("Retry")
        case .done where item.request.direction == .download:
            if let path = item.destinationPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
            }
        default:
            EmptyView()
        }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var status: String {
        let bytes = ByteCountFormatStyle(style: .file)
        switch item.state {
        case .queued:
            return "Waiting…"
        case .preparing:
            return item.request.isFolder ? "Preparing…" : "Starting…"
        case .running:
            var parts = ["\(Int64(item.bytesDone).formatted(bytes)) of \(Int64(item.bytesTotal).formatted(bytes))"]
            if item.speed > 0 { parts.append("\(Int64(item.speed).formatted(bytes))/s") }
            if let eta = item.eta { parts.append(Self.etaText(eta)) }
            if item.fileCount > 1 { parts.append("\(item.fileCount) files") }
            return parts.joined(separator: " — ")
        case .done(let copied, let skipped):
            let size = Int64(item.bytesDone).formatted(bytes)
            if item.request.isFolder {
                return skipped > 0 ? "Done — \(copied) copied, \(skipped) already there (\(size))" : "Done — \(copied) files (\(size))"
            }
            return "Done — \(size)"
        case .failed(let message, _):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    private static func etaText(_ eta: Duration) -> String {
        let seconds = Int(eta.components.seconds)
        if seconds < 60 { return "\(max(1, seconds)) s left" }
        if seconds < 3600 { return "\(seconds / 60) min left" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min left"
    }
}
