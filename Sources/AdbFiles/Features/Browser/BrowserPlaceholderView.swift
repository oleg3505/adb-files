import AdbKit
import SwiftUI

/// Detail area: connection states, device status, or (milestone 3) the file browser.
struct BrowserPlaceholderView: View {
    let store: DeviceStore

    var body: some View {
        switch store.phase {
        case .connecting:
            ProgressView("Connecting to ADB…")
        case .adbMissing:
            AdbMissingView(retry: store.retry)
        case .failed(let message):
            ContentUnavailableView {
                Label("Cannot Reach ADB", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", action: store.retry)
            }
        case .ready:
            if let device = store.selectedDevice {
                if device.state.isUsable {
                    ContentUnavailableView(
                        device.displayName, systemImage: "iphone",
                        description: Text("Connected. File browsing arrives in the next milestone.")
                    )
                } else {
                    DeviceStatusView(device: device)
                }
            } else {
                ContentUnavailableView(
                    "No Device Selected",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Connect an Android device with USB debugging enabled.")
                )
            }
        }
    }
}
