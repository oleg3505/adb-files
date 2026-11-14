import SwiftUI

/// Toolbar button with a badge for active transfers; opens the transfers popover.
struct TransfersButton: View {
    let queue: TransferQueue
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Group {
                if let summary = queue.activeSummary {
                    // While transfers run, the icon becomes a progress ring (like Safari downloads).
                    ProgressView(value: summary.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                }
            }
                .overlay(alignment: .topTrailing) {
                    if queue.activeCount > 0 {
                        Text("\(queue.activeCount)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.red))
                            .offset(x: 6, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .help("Transfers")
        .accessibilityLabel(queue.activeCount > 0 ? "Transfers, \(queue.activeCount) active" : "Transfers")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            TransfersPopover(queue: queue)
        }
    }
}
