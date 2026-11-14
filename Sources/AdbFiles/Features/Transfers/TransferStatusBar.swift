import SwiftUI

/// Bar at the bottom of the browser while transfers run: combined progress, speed and time left.
/// Clicking it opens the transfers list.
struct TransferStatusBar: View {
    let queue: TransferQueue
    @State private var isShowingList = false

    var body: some View {
        if let summary = queue.activeSummary {
            Button {
                isShowingList.toggle()
            } label: {
                HStack(spacing: 10) {
                    ProgressView(value: summary.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(text(summary))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .popover(isPresented: $isShowingList, arrowEdge: .top) { TransfersPopover(queue: queue) }
            .accessibilityLabel("Transfers in progress, \(Int(summary.fraction * 100)) percent")
            .help("Show transfers")
        }
    }

    private func text(_ summary: (fraction: Double, bytesDone: UInt64, bytesTotal: UInt64, speed: Double, eta: Duration?)) -> String {
        let bytes = ByteCountFormatStyle(style: .file)
        let count = queue.activeCount
        var parts = ["Copying \(count) \(count == 1 ? "item" : "items")", "\(Int(summary.fraction * 100))%"]
        if summary.bytesTotal > 0 {
            parts.append("\(Int64(summary.bytesDone).formatted(bytes)) of \(Int64(summary.bytesTotal).formatted(bytes))")
        }
        if summary.speed > 0 { parts.append("\(Int64(summary.speed).formatted(bytes))/s") }
        if let eta = summary.eta {
            let seconds = Int(eta.components.seconds)
            parts.append(seconds < 60 ? "\(max(1, seconds)) s left" : "\(seconds / 60) min left")
        }
        return parts.joined(separator: " — ")
    }
}
