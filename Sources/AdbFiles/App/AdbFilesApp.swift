import SwiftUI

@main
struct AdbFilesApp: App {
    // Bridges SwiftUI's App lifecycle to a classic AppKit delegate for launch-time setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // One device store for the whole app: every window shares the same ADB connection and device list.
    @State private var deviceStore: DeviceStore
    // Sync clients and the listing cache, shared by all windows.
    @State private var services = AppServices()

    init() {
        let store = DeviceStore()
        // Start connecting before the first window is built, so the device list is ready sooner.
        store.start()
        _deviceStore = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("AdbFiles") {
            RootView(store: deviceStore)
                .environment(services)
                .frame(minWidth: 700, minHeight: 420)
                .onChange(of: deviceStore.devices, initial: true) { _, devices in services.devicesChanged(devices) }
        }
        .commands {
            BrowserCommands()
            ViewCommands()
            TransferCommands(services: services)
            FileCommands()
        }
    }
}
