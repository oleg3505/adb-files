import Foundation
import os

/// Sync-protocol client for one device: directory listings and stat.
///
/// Keeps one persistent `sync:` connection for listings, opened lazily and dropped on any error so the
/// next call reconnects. Operations run one at a time on that connection. Cancelling the calling task, a
/// timeout, or `disconnect()` closes the connection.
///
/// The listing timeout limits *inactivity* (time without any data from the device), not total time, so a big folder
/// listed while transfers share the USB link still completes (ADR-002).
public actor AdbSyncClient {
    /// Device serial number.
    public let serial: String
    private let host: AdbHostClient
    private let listTimeout: Duration
    private let signposter = OSSignposter(logger: .adb)

    private var connection: AdbConnection?
    private var features: Set<String>?
    private var tail: Task<Void, Never>?
    /// At most two transfer connections per device, independent of the listing connection.
    private let transferLimiter = AsyncLimiter(limit: 2)
    /// One interactive connection per device for Quick Look and thumbnails (ADR-001), so they never wait behind
    /// transfers; previews ask with `.high` priority so they go before queued thumbnail reads.
    private let interactiveLimiter = AsyncLimiter(limit: 1)
    private var sessions: [UUID: AdbTransferSession] = [:]

    /// - Parameters:
    ///   - serial: The device to talk to.
    ///   - host: ADB server address and connect/request timeouts.
    ///   - listTimeout: Longest wait for the device while listing or stating: each write and each read must
    ///     complete within it. There is no limit on the total time (ADR-002).
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
        return try await serialized { try await self.performList(path) }
    }

    /// Stats a path without following a final symlink (with a trailing `/` the link is followed).
    public func lstat(_ path: String) async throws -> SyncStat {
        return try await serialized { try await self.performStat(path) }
    }

    /// Waits for a free transfer slot (two per device) and returns a session that owns it.
    /// - Parameter inactivity: Longest pause allowed between reads/writes; there is no overall time limit.
    public func openTransferSession(inactivity: Duration = .seconds(15)) async throws -> AdbTransferSession {
        let features = try await supportedFeatures()
        try await transferLimiter.acquire()
        let limiter = transferLimiter
        let token = UUID()
        let session = AdbTransferSession(serial: serial, host: host, features: features, inactivity: inactivity) { [weak self] in
            await limiter.release()
            await self?.forget(token)
        }
        sessions[token] = session
        return session
    }

    /// Waits for the interactive slot (one per device, separate from transfers) and returns a session that owns it.
    /// - Parameter priority: `.high` for user-initiated previews, `.normal` for background thumbnail reads.
    public func openInteractiveSession(
        priority: InteractivePriority = .normal, inactivity: Duration = .seconds(15)
    ) async throws -> AdbTransferSession {
        let features = try await supportedFeatures()
        try await interactiveLimiter.acquire(priority: priority == .high ? .high : .normal)
        let limiter = interactiveLimiter
        let token = UUID()
        let session = AdbTransferSession(serial: serial, host: host, features: features, inactivity: inactivity) { [weak self] in
            await limiter.release()
            await self?.forget(token)
        }
        sessions[token] = session
        return session
    }

    private func forget(_ id: UUID) {
        sessions[id] = nil
    }

    /// Closes the listing connection and every transfer session's connection (e.g. the device was unplugged).
    /// An operation reading from them ends with `AdbError.connectionClosed`; one still opening a connection or
    /// running the access-check shell finishes within its timeout.
    public func disconnect() async {
        await connection?.close()
        connection = nil
        for session in sessions.values { await session.abortConnection() }
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
            try await connection.sendRaw(request, timeout: listTimeout)
            var decoder = SyncListDecoder(v2: v2, directory: directory)
            reading: while true {
                while let item = try decoder.next() {
                    switch item {
                    case .entry(let file): entries.append(file)
                    case .done: break reading
                    }
                }
                // Inactivity limit: each chunk must arrive in time; a slow but steady listing is fine.
                decoder.append(try await connection.readAvailable(timeout: listTimeout))
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

        let output = try await AdbShell.run(AdbShell.accessCheck(directory), serial: serial, client: host, timeout: listTimeout)
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok": return
        case "denied": throw AdbError.permissionDenied(directory)
        case let other: throw AdbError.protocolError("unexpected access-check output \(other.debugDescription)")
        }
    }

    private func stat(_ path: String, on connection: AdbConnection) async throws -> SyncStat {
        let v2 = try await supports("stat_v2")
        try await connection.sendRaw(try SyncProtocol.encodeRequest(v2 ? .lstatV2 : .lstat, path: path), timeout: listTimeout)
        let reply = try await connection.readExactly(
            v2 ? SyncProtocol.statV2ReplySize : SyncProtocol.statV1ReplySize, timeout: listTimeout
        )
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
        try await supportedFeatures().contains(feature)
    }

    private func supportedFeatures() async throws -> Set<String> {
        if let features { return features }
        let fetched = try await host.features(serial: serial)
        features = fetched
        return fetched
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

/// Order in which interactive work gets the device connection.
public enum InteractivePriority: Sendable {
    /// Background work such as thumbnail reads.
    case normal
    /// User-initiated work such as a Quick Look download; goes before queued `.normal` work.
    case high
}
