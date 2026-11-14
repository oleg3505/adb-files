import AppKit
import os

/// Launch-time setup that SwiftUI's `App` cannot express on its own.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable (no .app bundle) starts as a background process
        // without a Dock icon or menu bar. `.regular` makes it a normal foreground app.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        Logger.ui.info("App launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
