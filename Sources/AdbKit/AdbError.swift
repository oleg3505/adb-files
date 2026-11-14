import Foundation

/// Errors produced by AdbKit, with user-readable descriptions.
public enum AdbError: Error, Sendable, Equatable, LocalizedError {
    /// Nothing listens on the ADB server port.
    case serverNotRunning
    /// No `adb` executable was found in the known locations or on `PATH`.
    case adbNotFound
    /// `adb start-server` ran but failed; carries its output.
    case serverStartFailed(String)
    /// The server answered `FAIL` with this message.
    case serverFailure(String)
    /// The connection closed before the expected data arrived.
    case connectionClosed
    /// The operation did not finish within its time budget.
    case timeout
    /// The server sent bytes that do not match the protocol.
    case protocolError(String)
    /// A network-level failure other than "connection refused".
    case connectionFailed(String)
    /// A request that cannot be encoded (e.g. longer than 65535 bytes).
    case invalidRequest(String)
    /// The path does not exist on the device.
    case notFound(String)
    /// The shell user may not read this directory.
    case permissionDenied(String)
    /// The path exists but is not a directory.
    case notADirectory(String)
    /// The device reported this errno for the path.
    case remoteError(path: String, errno: UInt32)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning: "The ADB server is not running."
        case .adbNotFound: "adb was not found. Install it with: brew install android-platform-tools"
        case .serverStartFailed(let output): "Could not start the ADB server: \(output)"
        case .serverFailure(let message): "ADB server error: \(message)"
        case .connectionClosed: "The connection to the ADB server was closed."
        case .timeout: "The ADB server did not respond in time."
        case .protocolError(let detail): "Unexpected response from the ADB server: \(detail)"
        case .connectionFailed(let detail): "Could not connect to the ADB server: \(detail)"
        case .invalidRequest(let detail): "Invalid ADB request: \(detail)"
        case .notFound(let path): "“\(path)” does not exist on the device."
        case .permissionDenied(let path): "You don’t have permission to view “\(path)”."
        case .notADirectory(let path): "“\(path)” is not a folder."
        case .remoteError(let path, let errno): "The device could not open “\(path)” (error \(errno))."
        }
    }
}
