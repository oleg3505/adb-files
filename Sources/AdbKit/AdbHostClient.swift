import Foundation
import os

/// Client for the ADB server's `host:*` services.
///
/// Each call opens its own short-lived connection, except `trackDevices()`, which keeps one open.
public struct AdbHostClient: Sendable {
    /// Server address.
    public var host: String
    /// Server port.
    public var port: UInt16
    /// Time allowed to establish a TCP connection.
    public var connectTimeout: Duration
    /// Time allowed for one request/response exchange.
    public var requestTimeout: Duration

    /// Creates a client for the given server.
    public init(
        host: String = AdbConnection.defaultHost, port: UInt16 = AdbConnection.defaultPort,
        connectTimeout: Duration = .seconds(2), requestTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
    }

    /// Returns the server's protocol version (`host:version`), e.g. 41.
    public func version() async throws -> Int {
        let payload = try await oneShot("host:version")
        let text = String(decoding: payload, as: UTF8.self)
        guard let version = Int(text, radix: 16) else {
            throw AdbError.protocolError("invalid version \(text.debugDescription)")
        }
        return version
    }

    /// Returns the current device list (`host:devices-l`).
    public func devices() async throws -> [Device] {
        let payload = try await oneShot("host:devices-l")
        return DeviceListParser.parse(String(decoding: payload, as: UTF8.self))
    }

    /// Returns the features both the device and the server support (`host-serial:<serial>:features`),
    /// e.g. `ls_v2`, `stat_v2`.
    public func features(serial: String) async throws -> Set<String> {
        let payload = try await oneShot("host-serial:\(serial):features")
        let text = String(decoding: payload, as: UTF8.self)
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    /// Streams the device list: the current list immediately, then a new list on every change
    /// (`host:track-devices-l`).
    ///
    /// The stream finishes with an error when the server goes away; cancelling the consuming task
    /// closes the connection.
    public func trackDevices() -> AsyncThrowingStream<[Device], Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await AdbConnection.connect(
                        host: client.host, port: client.port, timeout: client.connectTimeout
                    )
                    defer { Task { await connection.close() } }
                    try await connection.request("host:track-devices-l", timeout: client.requestTimeout)
                    Logger.adb.info("tracking devices")
                    while true {
                        // No timeout: the server only writes when the device list changes.
                        let payload = try await connection.readLengthPrefixed(timeout: nil)
                        continuation.yield(DeviceListParser.parse(String(decoding: payload, as: UTF8.self)))
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Wireless debugging (Android 11+)

    /// Pairs with a phone in Developer options › Wireless debugging › Pair device with pairing code
    /// (`host:pair:<code>:<host:port>`). The server answers `OKAY`, then `OKAY` + "Successfully paired to …" or
    /// `FAIL` + the reason (verified against adb 37 / protocol 41).
    /// - Parameters:
    ///   - address: The pairing `host:port` shown on the phone (not the connect port).
    ///   - code: The 6-digit pairing code.
    /// - Returns: The server's success message.
    /// - Throws: `AdbError.serverFailure` with adb's message (wrong code, phone not in pairing mode).
    public func pair(address: String, code: String, timeout: Duration = .seconds(45)) async throws -> String {
        let connection = try await AdbConnection.connect(host: host, port: port, timeout: connectTimeout)
        defer { Task { await connection.close() } }
        try await connection.request("host:pair:\(code):\(address)", timeout: requestTimeout)
        try await connection.expectOkay(timeout: timeout)
        let message = String(decoding: try await connection.readLengthPrefixed(timeout: requestTimeout), as: UTF8.self)
        guard message.hasPrefix("Successfully paired") else { throw AdbError.serverFailure(message) }
        return message
    }

    /// Connects to a phone over the network (`host:connect:<host:port>`; port 5555 when omitted). adb answers
    /// `OKAY` even when it fails, so the message decides: "connected to …" / "already connected to …" succeed.
    /// - Returns: The server's message.
    /// - Throws: `AdbError.serverFailure` with adb's message, e.g. "failed to connect to '…': Connection refused".
    public func connect(address: String, timeout: Duration = .seconds(30)) async throws -> String {
        let message = String(decoding: try await oneShot("host:connect:\(address)", timeout: timeout), as: UTF8.self)
        guard message.hasPrefix("connected to") || message.hasPrefix("already connected to") else {
            throw AdbError.serverFailure(message)
        }
        return message
    }

    /// Disconnects a network device (`host:disconnect:<host:port>`).
    /// - Throws: `AdbError.serverFailure` such as "no such device '…'".
    public func disconnect(address: String) async throws -> String {
        String(decoding: try await oneShot("host:disconnect:\(address)"), as: UTF8.self)
    }

    private func oneShot(_ service: String, timeout: Duration? = nil) async throws -> Data {
        let connection = try await AdbConnection.connect(host: host, port: port, timeout: connectTimeout)
        defer { Task { await connection.close() } }
        try await connection.request(service, timeout: timeout ?? requestTimeout)
        return try await connection.readLengthPrefixed(timeout: timeout ?? requestTimeout)
    }
}
