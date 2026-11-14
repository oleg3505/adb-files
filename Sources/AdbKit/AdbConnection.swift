import Foundation
import Network
import os

/// One TCP connection to the ADB server, speaking the host protocol.
///
/// All reads go through an internal `HostMessageDecoder`, so messages split across TCP segments are
/// reassembled. Cancelling the calling `Task` cancels the underlying socket.
public actor AdbConnection {
    /// Default ADB server address.
    public static let defaultHost = "127.0.0.1"
    /// Default ADB server port.
    public static let defaultPort: UInt16 = 5037

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.local.AdbFiles.AdbConnection")
    private var decoder = HostMessageDecoder()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Opens a connection to the ADB server.
    /// - Throws: `AdbError.serverNotRunning` when the port refuses connections, `.timeout`, or
    ///   `.connectionFailed`.
    public static func connect(
        host: String = defaultHost, port: UInt16 = defaultPort, timeout: Duration = .seconds(2)
    ) async throws -> AdbConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AdbError.invalidRequest("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let adb = AdbConnection(connection: connection)
        do {
            try await withTimeout(timeout) { try await adb.waitUntilReady() }
        } catch {
            connection.cancel()
            throw error
        }
        return adb
    }

    /// Sends a host service request and waits for `OKAY`.
    /// - Throws: `AdbError.serverFailure` with the server's message on `FAIL`.
    public func request(_ service: String, timeout: Duration? = .seconds(10)) async throws {
        let data = try HostProtocol.encodeRequest(service)
        try await withTimeout(timeout) {
            try await self.send(data)
            switch try await self.readStatus() {
            case .okay: return
            case .fail(let message): throw AdbError.serverFailure(message)
            }
        }
    }

    /// Reads one payload prefixed by a 4-hex-digit length. Pass `nil` to wait without a time limit.
    public func readLengthPrefixed(timeout: Duration? = .seconds(10)) async throws -> Data {
        try await withTimeout(timeout) { try await self.readLengthPrefixedUnbounded() }
    }

    /// Closes the connection. Safe to call more than once.
    public func close() {
        connection.cancel()
    }

    // MARK: - Internals

    private func readStatus() async throws -> HostStatus {
        while true {
            if let status = try decoder.decodeStatus() { return status }
            decoder.append(try await receiveChunk())
        }
    }

    private func readLengthPrefixedUnbounded() async throws -> Data {
        while true {
            if let payload = try decoder.decodeLengthPrefixed() { return payload }
            decoder.append(try await receiveChunk())
        }
    }

    private func waitUntilReady() async throws {
        let connection = self.connection
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .waiting(let error), .failed(let error):
                        // A refused TCP connect surfaces as `.waiting(ECONNREFUSED)`, not `.failed`.
                        once.run { continuation.resume(throwing: Self.map(error)) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
    }

    private func send(_ data: Data) async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func receiveChunk() async throws -> Data {
        let connection = self.connection
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else if isComplete {
                        continuation.resume(throwing: AdbError.connectionClosed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        try Task.checkCancellation()
        return data
    }

    private static func map(_ error: NWError) -> Error {
        switch error {
        case .posix(.ECONNREFUSED):
            return AdbError.serverNotRunning
        case .posix(.ECANCELED):
            return CancellationError()
        case .posix(.ECONNRESET), .posix(.EPIPE):
            return AdbError.connectionClosed
        default:
            Logger.adb.error("connection error: \(error.localizedDescription, privacy: .public)")
            return AdbError.connectionFailed(error.localizedDescription)
        }
    }
}

/// Runs `operation`, throwing `AdbError.timeout` if it does not finish within `timeout`.
/// On timeout the operation's task is cancelled (which cancels its socket). `nil` means no limit.
func withTimeout<T: Sendable>(
    _ timeout: Duration?, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let timeout else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AdbError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw AdbError.timeout }
        return result
    }
}

/// Guards a continuation that may be signalled from several callbacks so it resumes exactly once.
final class ResumeOnce: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
