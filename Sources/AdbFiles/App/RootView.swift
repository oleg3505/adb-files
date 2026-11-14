import SwiftUI

/// Top-level layout: device sidebar on the left, file browser on the right.
struct RootView: View {
    let store: DeviceStore

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(store: store)
        } detail: {
            BrowserPlaceholderView(store: store)
        }
    }
}
