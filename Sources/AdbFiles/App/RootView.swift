import SwiftUI

/// Top-level layout: device sidebar on the left, file browser on the right.
struct RootView: View {
    var body: some View {
        NavigationSplitView {
            DeviceSidebarView()
        } detail: {
            BrowserPlaceholderView()
        }
    }
}
