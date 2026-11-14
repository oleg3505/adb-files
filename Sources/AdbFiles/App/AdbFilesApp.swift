import SwiftUI

@main
struct AdbFilesApp: App {
    // Bridges SwiftUI's App lifecycle to a classic AppKit delegate for launch-time setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // One device store for the whole app: every window shares the same ADB connection and device list.
    @State private var deviceStore: DeviceStore

    init() {
        let store = DeviceStore()
        // Start connecting before the first window is built, so the device list is ready sooner.
        store.start()
        _deviceStore = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("AdbFiles") {
            RootView(store: deviceStore)
                .frame(minWidth: 700, minHeight: 420)
        }
    }
}
