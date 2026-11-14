import Foundation
import os

/// One transfer slot on a device: a dedicated `sync:` connection for downloads, uploads and walks.
///
/// Obtained from `AdbSyncClient.openTransferSession()`, which allows at most two per device. Always call
/// `close()` when done to free the slot. adbd ends the sync service after a `FAIL`, so the session reopens its
/// connection on the next operation. Every read and write has an inactivity limit; there is no overall limit.
public actor AdbTransferSession {
    public let serial: String
    private let host: AdbHostClient
    private let inactivity: Duration
    private let features: Set<String>
    private let onClose: @Sendable () async -> Void
    private let signposter = OSSignposter(logger: .adb)

    private var connection: AdbConnection?
    private var closed = false

    init(
        serial: String, host: AdbHostClient, features: Set<String>, inactivity: Duration,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.serial = serial
        self.host = host
        self.features = features
        self.inactivity = inactivity
        self.onClose = onClose
    }

    /// Closes the connection and frees the slot. Safe to call more than once.
    public func close() async {
        guard !closed else { return }
        closed = true
        await connection?.close()
        connection = nil
        await onClose()
    }

    /// Closes the connection under any operation in flight (device gone); the session stays usable.
    func abortConnection() async {
        await connection?.close()
        connection = nil
    }

    // MARK: - Single files

    /// Downloads one remote file to `target`, via `target.adbfiles-part`, then sets its modification time.
    /// - Parameters:
    ///   - overwrite: Replace an existing `target` (only inside a folder this transfer owns); otherwise an
    ///     existing target fails with `AdbError.localFileExists` and is left untouched.
    ///   - progress: Called with the number of bytes written for each chunk.
    public func download(
        _ remotePath: String, to target: URL, modificationDate: Date?, overwrite: Bool = false,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws {
        let temp = TransferIO.temporaryURL(for: target)
        // The temp name derives from a target name reserved by the caller, so a leftover is stale.
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw AdbError.localIOError("cannot create \(temp.path)")
        }
        let interval = signposter.beginInterval("transfer", id: signposter.makeSignpostID(), "down \(remotePath, privacy: .public)")
        defer { signposter.endInterval("transfer", interval) }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try await receive(remotePath, into: handle, progress: progress)
            try handle.close()
            if let modificationDate { TransferIO.setModificationDate(modificationDate, of: temp) }
            if overwrite, FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try TransferIO.moveWithoutOverwrite(temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Uploads one local file to `remotePath`, preserving its modification time and permissions.
    /// adbd creates missing parent folders and deletes the partial file if the transfer breaks.
    public func upload(_ source: URL, to remotePath: String, progress: @escaping @Sendable (Int) -> Void) async throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source)
        } catch {
            throw AdbError.localIOError("cannot read \(source.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let mtime = (attributes?[.modificationDate] as? Date) ?? Date()

        let interval = signposter.beginInterval("transfer", id: signposter.makeSignpostID(), "up \(remotePath, privacy: .public)")
        defer { signposter.endInterval("transfer", interval) }
        try await run { connection in
            try await connection.sendRaw(
                try SyncProtocol.encodeSendRequest(path: remotePath, mode: 0o100000 | (mode & 0o7777)), timeout: self.inactivity
            )
            while true {
                try Task.checkCancellation()
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: SyncProtocol.maxDataChunk) ?? Data()
                } catch {
                    throw AdbError.localIOError("cannot read \(source.lastPathComponent): \(error.localizedDescription)")
                }
                if chunk.isEmpty { break }
                try await connection.sendRaw(SyncProtocol.encodeData(chunk), timeout: self.inactivity)
                progress(chunk.count)
            }
            let seconds = UInt32(clamping: Int64(mtime.timeIntervalSince1970))
            try await connection.sendRaw(SyncProtocol.encodeDone(mtime: seconds), timeout: self.inactivity)
            let header = try await connection.readExactly(8, timeout: self.inactivity)
            if let length = try SyncProtocol.parseStatusHeader(header) {
                let message = try await connection.readExactly(length, timeout: self.inactivity)
                throw AdbError.serverFailure(String(decoding: message, as: UTF8.self))
            }
        }
    }

    /// Stats a remote path (no symlink follow), e.g. to check whether an upload target exists.
    public func lstat(_ path: String) async throws -> SyncStat {
        try await run { connection in
            let v2 = self.features.contains("stat_v2")
            try await connection.sendRaw(try SyncProtocol.encodeRequest(v2 ? .lstatV2 : .lstat, path: path), timeout: self.inactivity)
            let reply = try await connection.readExactly(
                v2 ? SyncProtocol.statV2ReplySize : SyncProtocol.statV1ReplySize, timeout: self.inactivity
            )
            return try SyncProtocol.decodeStat(reply, v2: v2)
        }
    }

    // MARK: - Folders

    /// Lists a remote folder recursively on this session's connection (folders before their contents).
    /// Symbolic links are skipped; unreadable subfolders appear empty.
    public func walk(_ remoteRoot: String) async throws -> [RemoteTreeEntry] {
        var result: [RemoteTreeEntry] = []
        var pending: [(remote: String, relative: String)] = [(RemotePath.normalized(remoteRoot), "")]
        while let (remote, relative) = pending.popLast() {
            let entries = try await list(remote)
            for file in entries.sorted(by: { $0.name < $1.name }) where !file.isSymlink {
                let childRelative = relative.isEmpty ? file.name : relative + "/" + file.name
                result.append(RemoteTreeEntry(relativePath: childRelative, file: file))
                if file.isDirectory { pending.append((file.path, childRelative)) }
            }
        }
        return result.sorted { $0.relativePath.split(separator: "/").count < $1.relativePath.split(separator: "/").count }
    }

    /// Downloads a remote folder into `localRoot` (created if needed). Files that already exist with the same
    /// size and modification time are skipped, so a Retry continues where it stopped. A file that fails is
    /// recorded and the rest continue. Folder modification times are set after their contents.
    public func downloadFolder(
        _ remoteRoot: String, into localRoot: URL, entries: [RemoteTreeEntry],
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderTransferResult {
        var result = FolderTransferResult()
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        for entry in entries where entry.file.isDirectory {
            try FileManager.default.createDirectory(
                at: localRoot.appendingPathComponent(entry.relativePath), withIntermediateDirectories: true
            )
        }
        for entry in entries where !entry.file.isDirectory {
            try Task.checkCancellation()
            let target = localRoot.appendingPathComponent(entry.relativePath)
            if let info = TransferIO.fileInfo(target), info.size == entry.file.size,
               let remoteDate = entry.file.modificationDate,
               Int64(info.mtime.timeIntervalSince1970) == Int64(remoteDate.timeIntervalSince1970) {
                result.skipped += 1
                progress(Int(clamping: entry.file.size))
                continue
            }
            do {
                try await download(entry.file.path, to: target, modificationDate: entry.file.modificationDate, overwrite: true, progress: progress)
                result.copied += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AdbError where Self.isPerFile(error) {
                result.failures[entry.relativePath] = error.localizedDescription
            }
        }
        // Post-order: deepest folders first, so writing children doesn't reset a parent's mtime.
        for entry in entries.reversed() where entry.file.isDirectory {
            if let date = entry.file.modificationDate {
                TransferIO.setModificationDate(date, of: localRoot.appendingPathComponent(entry.relativePath))
            }
        }
        return result
    }

    /// Uploads a local folder into `remoteRoot`. Files that already exist remotely with the same size and
    /// modification time are skipped (Retry). Unreadable local files are recorded and the rest continue.
    /// Empty folders are created with `mkdir -p`.
    public func uploadFolder(
        _ localRoot: URL, to remoteRoot: String, entries: [TransferIO.LocalEntry],
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderTransferResult {
        var result = FolderTransferResult()
        let root = RemotePath.normalized(remoteRoot)
        let filesByFolder = Set(entries.filter { !$0.isDirectory }.map { ($0.relativePath as NSString).deletingLastPathComponent })
        let emptyFolders = entries.filter { entry in
            entry.isDirectory && !filesByFolder.contains { $0 == entry.relativePath || $0.hasPrefix(entry.relativePath + "/") }
        }
        let foldersToMake = [root] + emptyFolders.map { RemotePath.join(root, $0.relativePath) }
        _ = try await AdbShell.run(AdbShell.command("mkdir -p", foldersToMake), serial: serial, client: host)

        for entry in entries where !entry.isDirectory {
            try Task.checkCancellation()
            let remote = RemotePath.join(root, entry.relativePath)
            if let existing = try? await lstat(remote), existing.errorCode == 0, existing.size == entry.size,
               existing.mtime == Int64(entry.modificationDate.timeIntervalSince1970) {
                result.skipped += 1
                progress(Int(clamping: entry.size))
                continue
            }
            do {
                try await upload(localRoot.appendingPathComponent(entry.relativePath), to: remote, progress: progress)
                result.copied += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AdbError where Self.isPerFile(error) {
                result.failures[entry.relativePath] = error.localizedDescription
            }
        }
        return result
    }

    // MARK: - Internals

    /// Errors that concern one file; the folder transfer records them and continues.
    private static func isPerFile(_ error: AdbError) -> Bool {
        switch error {
        case .serverFailure, .localIOError, .localFileExists, .remoteError: true
        default: false
        }
    }

    private func list(_ directory: String) async throws -> [RemoteFile] {
        try await run { connection in
            let v2 = self.features.contains("ls_v2")
            try await connection.sendRaw(
                try SyncProtocol.encodeRequest(v2 ? .listV2 : .list, path: RemotePath.listingPath(directory)), timeout: self.inactivity
            )
            var decoder = SyncListDecoder(v2: v2, directory: directory)
            var entries: [RemoteFile] = []
            while true {
                while let item = try decoder.next() {
                    switch item {
                    case .entry(let file): entries.append(file)
                    case .done: return entries
                    }
                }
                decoder.append(try await connection.readAvailable(timeout: self.inactivity))
            }
        }
    }

    private func receive(_ remotePath: String, into handle: FileHandle, progress: @escaping @Sendable (Int) -> Void) async throws {
        try await run { connection in
            try await connection.sendRaw(try SyncProtocol.encodeRequest(.recv, path: remotePath), timeout: self.inactivity)
            var decoder = SyncRecvDecoder()
            while true {
                while let item = try decoder.next() {
                    switch item {
                    case .data(let chunk):
                        do {
                            try handle.write(contentsOf: chunk)
                        } catch {
                            throw AdbError.localIOError(error.localizedDescription)
                        }
                        progress(chunk.count)
                    case .done:
                        return
                    }
                }
                try Task.checkCancellation()
                decoder.append(try await connection.readAvailable(timeout: self.inactivity))
            }
        }
    }

    /// Runs `body` on the session's connection, opening it if needed. Any failure drops the connection,
    /// because adbd ends the sync service after `FAIL` and a broken stream can't be resumed.
    private func run<T: Sendable>(_ body: (AdbConnection) async throws -> T) async throws -> T {
        guard !closed else { throw AdbError.connectionClosed }
        let connection: AdbConnection
        if let existing = self.connection {
            connection = existing
        } else {
            connection = try await AdbConnection.openDeviceService(
                "sync:", serial: serial, host: host.host, port: host.port,
                connectTimeout: host.connectTimeout, requestTimeout: host.requestTimeout
            )
            self.connection = connection
        }
        do {
            return try await body(connection)
        } catch {
            await connection.close()
            if self.connection === connection { self.connection = nil }
            if error is CancellationError, !Task.isCancelled { throw AdbError.connectionClosed }
            throw error
        }
    }
}
