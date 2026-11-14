import Foundation
import os

/// Rename, move, copy, delete and create folders on a device, via `shell:` commands built only with `AdbShell`.
///
/// toybox's `-n` (no clobber) skips silently and `shell:` has no exit status, so every operation checks the
/// source and the target before running and verifies the result afterwards. Name clashes are compared
/// case-insensitively, because shared storage (`/sdcard`, FUSE) is case-insensitive on current Android.
/// Every command puts `--` before paths, so a name like `-rf` is never read as an option.
public struct AdbFileOperations: Sendable {
    public let serial: String
    private let client: AdbSyncClient
    private let host: AdbHostClient

    /// - Parameters:
    ///   - client: Used for stats and listings (its listing connection).
    ///   - host: Server address for the `shell:` connections.
    public init(serial: String, client: AdbSyncClient, host: AdbHostClient = AdbHostClient()) {
        self.serial = serial
        self.client = client
        self.host = host
    }

    // MARK: - Rename

    /// Renames `path` to `newName` in the same folder. Returns the new path.
    /// - Throws: `.notFound`, `.alreadyExists`, `.operationFailed`, `.invalidRequest`.
    @discardableResult
    public func rename(_ path: String, to newName: String) async throws -> String {
        let source = RemotePath.normalized(path)
        guard let parent = RemotePath.parent(of: source) else { throw AdbError.invalidRequest("cannot rename /") }
        let oldName = (source as NSString).lastPathComponent
        let target = RemotePath.join(parent, newName)
        guard newName != oldName else { return source }
        try await requireExists(source)

        let names = try await self.names(in: parent)
        let caseOnly = newName.lowercased() == oldName.lowercased()
        // The source itself matches case-insensitively in a case-only rename; it is not a clash.
        if names.contains(where: { $0 != oldName && $0.lowercased() == newName.lowercased() }) {
            throw AdbError.alreadyExists(target)
        }

        if caseOnly {
            // On case-insensitive storage `mv a A` may do nothing; go through a unique temporary name.
            let temp = RemotePath.join(parent, ".adbfiles-rename-\(UUID().uuidString.prefix(8))")
            try await shell(AdbShell.command("mv -T --", [source, temp]))
            do {
                try await shell(AdbShell.command("mv -T --", [temp, target]))
            } catch {
                do {
                    try await shell(AdbShell.command("mv -T --", [temp, source]))
                } catch {
                    throw AdbError.operationFailed(
                        "Renaming failed and the item was left as “\((temp as NSString).lastPathComponent)” in \(parent)."
                    )
                }
                throw error
            }
        } else {
            try await shell(AdbShell.command("mv -n -T --", [source, target]))
        }

        // Verify by exact name: a stat can't tell `a.txt` from `A.txt` on case-insensitive storage.
        let after = try await self.names(in: parent)
        guard after.contains(newName), !after.contains(oldName) else {
            throw AdbError.operationFailed("The device did not rename “\(oldName)”.")
        }
        log("rename", ok: true)
        return target
    }

    // MARK: - Move / copy

    /// Moves items into `folder`. Returns the result per source path (the new path on success).
    public func move(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>] {
        await transfer(paths, into: folder, copy: false)
    }

    /// Copies items into `folder` with `cp -a` (timestamps and modes kept). Returns the result per source path.
    /// A copy that fails partway leaves the partial destination in place and says so.
    public func copy(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>] {
        await transfer(paths, into: folder, copy: true)
    }

    private func transfer(_ paths: [String], into folder: String, copy: Bool) async -> [String: Result<String, AdbError>] {
        let destination = RemotePath.normalized(folder)
        var results: [String: Result<String, AdbError>] = [:]
        var names: [String]
        do {
            let info = try await client.lstat(destination)
            guard info.errorCode == 0 else { throw AdbError.notFound(destination) }
            guard info.isDirectory else { throw AdbError.notADirectory(destination) } // also refuses symlinks
            names = try await self.names(in: destination)
        } catch {
            let failure = Self.adbError(error)
            for path in paths { results[path] = .failure(failure) }
            return results
        }

        for path in paths {
            let source = RemotePath.normalized(path)
            let name = (source as NSString).lastPathComponent
            let target = RemotePath.join(destination, name)
            do {
                if destination == source || destination.hasPrefix(source + "/") {
                    throw AdbError.operationFailed("“\(name)” can’t be \(copy ? "copied" : "moved") into itself.")
                }
                if !copy, RemotePath.parent(of: source) == destination { results[path] = .success(source); continue }
                let sourceInfo = try await requireExists(source)
                if names.contains(where: { $0.lowercased() == name.lowercased() }) { throw AdbError.alreadyExists(target) }
                let command = copy ? AdbShell.command("cp -a -n -T --", [source, target]) : AdbShell.command("mv -n -T --", [source, target])
                do {
                    try await shell(command, timeout: .seconds(120))
                } catch AdbError.operationFailed(let message) where copy {
                    throw AdbError.operationFailed(message + "\nA partial copy may remain at \(target).")
                }
                let targetInfo = try await client.lstat(target)
                let sourceAfter = try await client.lstat(source)
                let ok = copy
                    ? targetInfo.errorCode == 0 && targetInfo.isDirectory == sourceInfo.isDirectory && sourceAfter.errorCode == 0
                    : targetInfo.errorCode == 0 && sourceAfter.errorCode != 0
                guard ok else { throw AdbError.operationFailed("The device did not \(copy ? "copy" : "move") “\(name)”.") }
                names.append(name)
                results[path] = .success(target)
            } catch {
                results[path] = .failure(Self.adbError(error))
            }
        }
        log(copy ? "copy" : "move", ok: results.values.allSatisfy { if case .success = $0 { true } else { false } })
        return results
    }

    // MARK: - Delete

    /// Deletes files and folders recursively (permanently — there is no trash). Returns the result per path.
    public func delete(_ paths: [String]) async -> [String: Result<Void, AdbError>] {
        var results: [String: Result<Void, AdbError>] = [:]
        var batches: [[String]] = [[]]
        var bytes = 0
        for path in paths.map(RemotePath.normalized) {
            if bytes + path.utf8.count > 8_000, let last = batches.last, !last.isEmpty {
                batches.append([])
                bytes = 0
            }
            batches[batches.count - 1].append(path)
            bytes += path.utf8.count + 3
        }
        for batch in batches where !batch.isEmpty {
            var batchError: AdbError?
            do {
                try await shell(AdbShell.command("rm -r --", batch), timeout: .seconds(120))
            } catch {
                batchError = Self.adbError(error)
            }
            for path in batch {
                // A path counts as deleted only if it is really gone.
                if let info = try? await client.lstat(path), info.errorCode == 2 {
                    results[path] = .success(())
                } else {
                    results[path] = .failure(batchError ?? .operationFailed("The device did not delete “\((path as NSString).lastPathComponent)”."))
                }
            }
        }
        log("delete", ok: results.values.allSatisfy { if case .success = $0 { true } else { false } })
        return results
    }

    // MARK: - New folder

    /// Creates one folder (fails if a file or folder with that name exists, compared case-insensitively).
    public func makeDirectory(_ path: String) async throws {
        let target = RemotePath.normalized(path)
        guard let parent = RemotePath.parent(of: target) else { throw AdbError.invalidRequest("cannot create /") }
        let name = (target as NSString).lastPathComponent
        if try await names(in: parent).contains(where: { $0.lowercased() == name.lowercased() }) {
            throw AdbError.alreadyExists(target)
        }
        try await shell(AdbShell.command("mkdir --", [target]))
        let info = try await client.lstat(target)
        guard info.errorCode == 0, info.isDirectory else { throw AdbError.operationFailed("The device did not create “\(name)”.") }
        log("mkdir", ok: true)
    }

    // MARK: - Helpers

    @discardableResult
    private func requireExists(_ path: String) async throws -> SyncStat {
        let info = try await client.lstat(path)
        guard info.errorCode == 0 else { throw AdbError.notFound(path) }
        return info
    }

    private func names(in folder: String) async throws -> [String] {
        try await client.list(folder).map(\.name)
    }

    private func shell(_ command: String, timeout: Duration = .seconds(10)) async throws {
        try await AdbShell.runChecked(command, serial: serial, client: host, timeout: timeout)
    }

    private func log(_ operation: String, ok: Bool) {
        Logger.adb.info("fileop \(operation, privacy: .public) ok=\(ok)")
    }

    private static func adbError(_ error: Error) -> AdbError {
        if let error = error as? AdbError { return error }
        if error is CancellationError { return .operationFailed("The operation was interrupted; its result is unknown.") }
        return .operationFailed(error.localizedDescription)
    }
}
