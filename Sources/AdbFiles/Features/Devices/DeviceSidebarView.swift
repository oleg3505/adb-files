import SwiftUI

/// Sidebar listing connected devices. Populated in milestone 2.
struct DeviceSidebarView: View {
    var body: some View {
        List {
            Section("Devices") {
                Label("No devices", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}
