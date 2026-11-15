import AdbKit
import os
import SwiftUI

/// Sidebar listing connected devices, then the fixed Locations of the selected device.
struct DeviceSidebarView: View {
    let store: DeviceStore
    /// The browser of this window (nil while no usable device is shown), as for the Go menu.
    @FocusedValue(\.browser) private var browser

    var body: some View {
        List(selection: selection) {
            Section("Devices") {
                if store.devices.isEmpty {
                    Label(emptyText, systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(store.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.serial)
                            .contextMenu {
                                if WifiConnectModel.isNetworkSerial(device.serial) {
                                    Button("Disconnect") { disconnect(device.serial) }
                                }
                            }
                    }
                }
            }
            Section("Locations") {
                ForEach(Bookmark.all) { bookmark in
                    let isCurrent = browser?.path == bookmark.path
                    Button {
                        browser?.navigate(to: bookmark.path, action: "bookmark")
                    } label: {
                        Label(bookmark.name, systemImage: bookmark.symbol)
                            .fontWeight(isCurrent ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .disabled(browser == nil)
                    .selectionDisabled()
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .help(bookmark.path)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func disconnect(_ serial: String) {
        Task {
            do {
                let message = try await AdbHostClient().disconnect(address: serial)
                Logger.ui.info("wifi disconnect serial=\(serial, privacy: .public): \(message, privacy: .public)")
            } catch {
                Logger.ui.error("wifi disconnect failed serial=\(serial, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
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
