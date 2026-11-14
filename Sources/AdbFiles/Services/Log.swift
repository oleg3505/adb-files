import os

extension Logger {
    /// Constant subsystem: a bare executable has no bundle, so `Bundle.main.bundleIdentifier` would be nil.
    private static let subsystem = "dev.local.AdbFiles"

    /// UI events and user actions.
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// File transfer queue and progress.
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
}
