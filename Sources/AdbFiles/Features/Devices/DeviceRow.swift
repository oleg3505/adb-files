import AdbKit
import SwiftUI

/// One device in the sidebar: icon, name and, unless fully connected, its state.
struct DeviceRow: View {
    let device: Device

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                if !device.state.isUsable {
                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .opacity(device.state.isUsable ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.displayName), \(stateText)")
    }

    private var symbol: String {
        switch device.state {
        case .unauthorized, .noPermissions: "lock.iphone"
        default: device.isEmulator ? "apps.iphone" : "iphone"
        }
    }

    private var stateText: String {
        switch device.state {
        case .device: "Connected"
        case .unauthorized: "Unauthorized"
        case .offline: "Offline"
        case .noPermissions: "No permissions"
        default: device.state.rawValue.capitalized
        }
    }
}
