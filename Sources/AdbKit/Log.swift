import os

extension Logger {
    /// ADB protocol and server management. Same subsystem as the app's loggers.
    static let adb = Logger(subsystem: "dev.local.AdbFiles", category: "adb")
}
