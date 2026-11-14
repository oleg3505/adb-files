import AdbKit
import SwiftUI

/// Detail shown for a selected device that cannot be browsed yet (unauthorized, offline, …).
struct DeviceStatusView: View {
    let device: Device

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }

    private var title: String { device.displayName }

    private var symbol: String {
        switch device.state {
        case .unauthorized, .noPermissions: "lock.iphone"
        case .offline: "iphone.slash"
        default: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch device.state {
        case .unauthorized: "Confirm USB debugging on your phone."
        case .authorizing: "Waiting for the device to finish authorization…"
        case .offline: "The device is offline. Reconnect the cable or wait for it to finish booting."
        case .noPermissions: "The system denied access to this USB device."
        default: "The device is in \(device.state.rawValue) mode and cannot be browsed."
        }
    }
}
