import Foundation

/// Builds and runs commands on the device's `shell:` service.
///
/// Every argument that is not a literal written in this codebase must go through `quote(_:)`.
/// Never build shell strings any other way.
public enum AdbShell {
    /// Runs `command` on the device and returns its combined output.
    /// The v1 `shell:` service returns no exit status; encode results in the output instead.
    public static func run(
        _ command: String, serial: String, client: AdbHostClient = AdbHostClient(), timeout: Duration = .seconds(10)
    ) async throws -> String {
        let connection = try await AdbConnection.openDeviceService(
            "shell:" + command, serial: serial, host: client.host, port: client.port,
            connectTimeout: client.connectTimeout, requestTimeout: client.requestTimeout
        )
        defer { Task { await connection.close() } }
        let output = try await connection.readToEnd(timeout: timeout)
        return String(decoding: output, as: UTF8.self)
    }

    /// Wraps an argument in single quotes, replacing each `'` with `'\''`, so the device shell
    /// passes it through unchanged (spaces, `$`, backticks, newlines, Cyrillic, emoji).
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds `program 'arg1' 'arg2' …`. `program` must be a trusted literal such as `mkdir -p`.
    public static func command(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments.map(quote)).joined(separator: " ")
    }

    /// Prints `ok` when the shell user can read and enter `path`, otherwise `denied`.
    /// The `shell:` (v1) service returns no exit status, so the result is an echoed marker.
    public static func accessCheck(_ path: String) -> String {
        let quoted = quote(path)
        return "test -r \(quoted) -a -x \(quoted) && echo ok || echo denied"
    }
}
