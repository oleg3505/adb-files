import AdbKit
import SwiftUI

/// Sidebar listing connected devices.
struct DeviceSidebarView: View {
    let store: DeviceStore

    var body: some View {
        List(selection: selection) {
            Section("Devices") {
                if store.devices.isEmpty {
                    Label(emptyText, systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(store.devices) { device in
                        DeviceRow(device: device).tag(device.serial)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private var selection: Binding<String?> {
        Binding(get: { store.selectedSerial }, set: { store.select($0) })
    }

    private var emptyText: String {
        switch store.phase {
        case .connecting: "Connecting…"
        case .adbMissing: "adb not found"
        case .failed: "Not connected"
        case .ready: "No devices"
        }
    }
}
