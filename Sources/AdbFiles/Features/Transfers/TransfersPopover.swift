import SwiftUI

/// List of transfers with progress, speed, ETA and per-row actions.
struct TransfersPopover: View {
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.items.contains { $0.state.isFinal })
            }
            .padding(10)
            Divider()
            if queue.items.isEmpty {
                ContentUnavailableView(
                    "No Transfers", systemImage: "arrow.up.arrow.down",
                    description: Text("Drag files to or from the file list, or use File › Download To… and Upload…")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.items.reversed()) { item in
                            TransferRow(item: item, queue: queue)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }
}
