import Foundation
import os

/// Sync-protocol client for one device: directory listings and stat.
///
/// Keeps one persistent `sync:` connection for listings, opened lazily and dropped on any error so the
/// next call reconnects. Operations run one at a time on that connection. Cancelling the calling task, a
/// timeout, or `disconnect()` closes the connection.
public actor AdbSyncClient {
    /// Device serial number.
    public let serial: String
    private let host: AdbHostClient
    private let listTimeout: Duration
    private let signposter = OSSignposter(logger: .adb)

    private var connection: AdbConnection?
    private var features: Set<String>?
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - serial: The device to talk to.
    ///   - host: ADB server address and connect/request timeouts.
    ///   - listTimeout: Upper bound for one listing, including the empty-folder checks.
    public init(serial: String, host: AdbHostClient = AdbHostClient(), listTimeout: Duration = .seconds(10)) {
        self.serial = serial
        self.host = host
        self.listTimeout = listTimeout
    }

    /// Lists a directory (symlinks to directories are followed).
    /// - Returns: The entries, without `.` and `..`; empty for an empty, readable directory.
    /// - Throws: `AdbError.notFound`, `.permissionDenied`, `.notADirectory`, `.remoteError`, `.timeout`,
    ///   connection errors, or `CancellationError`.
    public func list(_ directory: String) async throws -> [RemoteFile] {
        let path = RemotePath.normalized(directory)
        let timeout = listTimeout
        return try await serialized {
            try await withTimeout(timeout) { try await self.performList(path) }
        }
    }

    /// Stats a path without following a final symlink (with a trailing `/` the link is followed).
    public func lstat(_ path: String) async throws -> SyncStat {
        let timeout = listTimeout
        return try await serialized {
            try await withTimeout(timeout) { try await self.performStat(path) }
        }
    }

    /// Closes the listing connection (e.g. the device was unplugged). An operation reading from it ends
    /// with `AdbError.connectionClosed`; one still opening a connection or running the access-check shell
    /// finishes within `listTimeout`.
    public func disconnect() async {
        await connection?.close()
        connection = nil
    }

    // MARK: - Operations

    private func performList(_ directory: String) async throws -> [RemoteFile] {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("list", id: signpostID, "\(directory, privacy: .public)")
        let clock = ContinuousClock()
        let started = clock.now
        var entries: [RemoteFile] = []
        defer {
            signposter.endInterval("list", interval, "\(entries.count) entries")
        }

        do {
            let connection = try await syncConnection()
            let v2 = try await supports("ls_v2")
            let request = try SyncProtocol.encodeRequest(v2 ? .listV2 : .list, path: RemotePath.listingPath(directory))
            try await connection.sendRaw(request, timeout: nil)
            var decoder = SyncListDecoder(v2: v2, directory: directory)
            reading: while true {
                while let item = try decoder.next() {
                    switch item {
                    case .entry(let file): entries.append(file)
                    case .done: break reading
                    }
                }
                decoder.append(try await connection.readAvailable(timeout: nil))
            }
            if entries.isEmpty { try await classifyEmptyListing(directory, on: connection) }
        } catch {
            await dropConnection()
            throw Self.surface(error)
        }

        let elapsed = clock.now - started
        Logger.adb.info(
            "list path=\(directory, privacy: .public) entries=\(entries.count) ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"
        )
        return entries
    }

    private func performStat(_ path: String) async throws -> SyncStat {
        do {
            return try await stat(path, on: try await syncConnection())
        } catch {
            await dropConnection()
            throw Self.surface(error)
        }
    }

    /// A closed socket surfaces as `CancellationError` (ECANCELED). If this operation itself was not
    /// cancelled, the connection was closed under it (`disconnect()`), so report that instead.
    private static func surface(_ error: Error) -> Error {
        if error is CancellationError, !Task.isCancelled { return AdbError.connectionClosed }
        return error
    }

    /// adbd answers a missing or unreadable directory with an empty listing, so tell them apart.
    private func classifyEmptyListing(_ directory: String, on connection: AdbConnection) async throws {
        let info = try await stat(RemotePath.listingPath(directory), on: connection)
        switch info.errorCode {
        case 0: break
        // errno values are only reported by STA2/LST2; v1 STAT maps a failed stat to 2 (all zeros).
        case 2: throw AdbError.notFound(directory)
        case 13: throw AdbError.permissionDenied(directory) // EACCES: a parent can't be traversed
        case 20: throw AdbError.notADirectory(directory) // ENOTDIR
        default: throw AdbError.remoteError(path: directory, errno: info.errorCode)
        }
        guard info.isDirectory else { throw AdbError.notADirectory(directory) }

        let output = try await AdbShell.run(AdbShell.accessCheck(directory), serial: serial, client: host)
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok": return
        case "denied": throw AdbError.permissionDenied(directory)
        case let other: throw AdbError.protocolError("unexpected access-check output \(other.debugDescription)")
        }
    }

    private func stat(_ path: String, on connection: AdbConnection) async throws -> SyncStat {
        let v2 = try await supports("stat_v2")
        try await connection.sendRaw(try SyncProtocol.encodeRequest(v2 ? .lstatV2 : .lstat, path: path), timeout: nil)
        let reply = try await connection.readExactly(v2 ? SyncProtocol.statV2ReplySize : SyncProtocol.statV1ReplySize, timeout: nil)
        return try SyncProtocol.decodeStat(reply, v2: v2)
    }

    // MARK: - Connection management

    private func syncConnection() async throws -> AdbConnection {
        if let connection { return connection }
        let connection = try await AdbConnection.openDeviceService(
            "sync:", serial: serial, host: host.host, port: host.port,
            connectTimeout: host.connectTimeout, requestTimeout: host.requestTimeout
        )
        self.connection = connection
        return connection
    }

    private func supports(_ feature: String) async throws -> Bool {
        if let features { return features.contains(feature) }
        let fetched = try await host.features(serial: serial)
        features = fetched
        return fetched.contains(feature)
    }

    private func dropConnection() async {
        await connection?.close()
        connection = nil
    }

    /// Runs operations one after another; the actor alone would interleave them at each `await`.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            _ = await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
