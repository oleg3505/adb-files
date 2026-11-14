import AdbKit
import SwiftUI

/// Detail area: connection states, device status, or the file browser for a usable device.
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
                    BrowserView(device: device) { serial in
                        store.devices.contains { $0.serial == serial && $0.state.isUsable }
                    }
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
