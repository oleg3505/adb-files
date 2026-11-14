import Foundation
import Network
import os

/// One TCP connection to the ADB server, speaking the host protocol.
///
/// All reads go through an internal `HostMessageDecoder`, so messages split across TCP segments are
/// reassembled. Cancelling the calling `Task` cancels the underlying socket.
///
/// - Important: Run one exchange at a time. Concurrent requests or reads on the same connection share the
///   receive buffer and would interleave bytes; open another connection instead.
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

    // Each primitive below resumes its continuation from the Network callback OR from `onCancel`,
    // whichever comes first, so a cancelled task never waits for a callback that may not arrive.

    private func waitUntilReady() async throws {
        let connection = self.connection
        let queue = self.queue
        let box = ContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try await box.wait {
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(.success(()))
                    case .waiting(let error), .failed(let error):
                        // A refused TCP connect surfaces as `.waiting(ECONNREFUSED)`, not `.failed`.
                        box.resume(.failure(Self.map(error)))
                    case .cancelled:
                        box.resume(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            box.cancel()
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
    }

    private func send(_ data: Data) async throws {
        let connection = self.connection
        let box = ContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try await box.wait {
                connection.send(content: data, completion: .contentProcessed { error in
                    box.resume(error.map { .failure(Self.map($0)) } ?? .success(()))
                })
            }
        } onCancel: {
            box.cancel()
            connection.cancel()
        }
    }

    private func receiveChunk() async throws -> Data {
        let connection = self.connection
        let box = ContinuationBox<Data>()
        return try await withTaskCancellationHandler {
            try await box.wait {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        box.resume(.success(data))
                    } else if let error {
                        box.resume(.failure(Self.map(error)))
                    } else if isComplete {
                        box.resume(.failure(AdbError.connectionClosed))
                    } else {
                        box.resume(.success(Data()))
                    }
                }
            }
        } onCancel: {
            box.cancel()
            connection.cancel()
        }
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

/// A continuation that can be resumed exactly once, either by a callback or by cancellation.
///
/// If `cancel()` runs before `wait` installs the continuation (a task that is already cancelled runs its
/// `onCancel` first), `wait` throws `CancellationError` without calling `start`.
final class ContinuationBox<T: Sendable>: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<T, Error>)
        case cancelled
        case finished
    }

    private let state = OSAllocatedUnfairLock(initialState: State.idle)

    /// Suspends until `resume` or `cancel`. `start` kicks off the callback-based work.
    func wait(_ start: () -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let proceed = state.withLock { state -> Bool in
                guard case .idle = state else { return false }
                state = .waiting(continuation)
                return true
            }
            if proceed {
                start()
            } else {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Delivers the result; ignored if the continuation already resumed.
    func resume(_ result: Result<T, Error>) {
        take(next: .finished)?.resume(with: result)
    }

    /// Resumes with `CancellationError`, or makes a later `wait` fail immediately.
    func cancel() {
        take(next: .cancelled)?.resume(throwing: CancellationError())
    }

    private func take(next: State) -> CheckedContinuation<T, Error>? {
        state.withLock { state in
            switch state {
            case .waiting(let continuation):
                state = .finished
                return continuation
            case .idle:
                if case .cancelled = next { state = .cancelled }
                return nil
            case .cancelled, .finished:
                return nil
            }
        }
    }
}

/// Guards a callback that may fire several times so `body` runs exactly once.
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
