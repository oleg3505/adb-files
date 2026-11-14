import SwiftUI

@main
struct AdbFilesApp: App {
    // Bridges SwiftUI's App lifecycle to a classic AppKit delegate for launch-time setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AdbFiles") {
            RootView()
                .frame(minWidth: 700, minHeight: 420)
        }
    }
}
