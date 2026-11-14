import Foundation
import Network
@testable import AdbKit

/// Minimal in-process TCP server on 127.0.0.1 that scripts ADB host-protocol responses.
final class FakeAdbServer: Sendable {
    /// One accepted client connection, with helpers to read requests and write raw responses.
    struct Client: Sendable {
        let connection: NWConnection

        /// Reads one host request (`<4 hex length><payload>`) and returns the payload.
        func readRequest() async throws -> String {
            let header = try await read(exactly: 4)
            guard let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
                throw AdbError.protocolError("bad request header")
            }
            return String(decoding: try await read(exactly: length), as: UTF8.self)
        }

        /// Writes raw bytes.
        func write(_ text: String) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }

        /// Writes a length-prefixed payload.
        func writeFramed(_ payload: String) async throws {
            try await write(String(format: "%04x", payload.utf8.count) + payload)
        }

        /// Writes raw bytes.
        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }

        /// Reads one sync request: 4-byte id + LE UInt32 length + path.
        func readSyncRequest() async throws -> (id: String, path: String) {
            let header = try await read(exactly: 8)
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let length = header.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            return (id, String(decoding: try await read(exactly: length), as: UTF8.self))
        }

        /// Reads an 8-byte sync header: 4-byte id + LE UInt32 (a length, or the mtime for DONE).
        func readSyncHeader() async throws -> (id: String, value: UInt32) {
            let header = try await read(exactly: 8)
            let value = header.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return (String(decoding: header.prefix(4), as: UTF8.self), value)
        }

        func close() { connection.cancel() }

        func read(exactly count: Int) async throws -> Data {
            guard count > 0 else { return Data() }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? AdbError.connectionClosed)
                    }
                }
            }
        }
    }

    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// Starts a server on an ephemeral port; `handler` runs once per accepted client.
    static func start(handler: @escaping @Sendable (Client) async throws -> Void) async throws -> FakeAdbServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FakeAdbServer")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { try? await handler(Client(connection: connection)) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return FakeAdbServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }

    /// A client pointed at this server with short timeouts.
    func client(requestTimeout: Duration = .seconds(2)) -> AdbHostClient {
        AdbHostClient(host: "127.0.0.1", port: port, connectTimeout: .seconds(1), requestTimeout: requestTimeout)
    }
}
