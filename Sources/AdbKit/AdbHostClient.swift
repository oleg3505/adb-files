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

    private func oneShot(_ service: String) async throws -> Data {
        let connection = try await AdbConnection.connect(host: host, port: port, timeout: connectTimeout)
        defer { Task { await connection.close() } }
        try await connection.request(service, timeout: requestTimeout)
        return try await connection.readLengthPrefixed(timeout: requestTimeout)
    }
}
