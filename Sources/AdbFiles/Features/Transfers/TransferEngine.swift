import AdbKit
import Foundation

/// Progress reported by an engine while it runs one transfer.
enum TransferEvent: Sendable, Equatable {
    /// Totals are known (after walking a folder).
    case prepared(totalBytes: UInt64, files: Int)
    /// More bytes were copied.
    case bytes(Int)
}

/// Runs transfers. `AdbTransferEngine` in production, a scripted fake in tests.
protocol TransferEngine: Sendable {
    /// Copies `request` to `destination` (full path of the resolved target).
    func run(
        _ request: TransferRequest, destination: String, events: @escaping @Sendable (TransferEvent) -> Void
    ) async throws -> FolderTransferResult

    /// Whether `path` exists on the device (used to pick keep-both names for uploads).
    /// Throws when it can't tell: an unknown answer must never be treated as "the name is free".
    func remoteExists(serial: String, path: String) async throws -> Bool
}

/// Real engine: one transfer session per transfer, at most two per device (enforced by `AdbSyncClient`).
struct AdbTransferEngine: TransferEngine {
    let client: @Sendable (String) async -> AdbSyncClient

    func run(
        _ request: TransferRequest, destination: String, events: @escaping @Sendable (TransferEvent) -> Void
    ) async throws -> FolderTransferResult {
        let session = try await client(request.serial).openTransferSession()
        do {
            let result = try await perform(request, destination: destination, session: session, events: events)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    private func perform(
        _ request: TransferRequest, destination: String, session: AdbTransferSession,
        events: @escaping @Sendable (TransferEvent) -> Void
    ) async throws -> FolderTransferResult {
        let progress: @Sendable (Int) -> Void = { events(.bytes($0)) }
        switch (request.direction, request.isFolder) {
        case (.download, false):
            events(.prepared(totalBytes: request.size, files: 1))
            try await session.download(
                request.sourcePath, to: URL(fileURLWithPath: destination), modificationDate: request.modificationDate, progress: progress
            )
            var result = FolderTransferResult()
            result.copied = 1
            return result
        case (.download, true):
            let entries = try await session.walk(request.sourcePath)
            let files = entries.filter { !$0.file.isDirectory }
            events(.prepared(totalBytes: files.reduce(0) { $0 + $1.file.size }, files: files.count))
            return try await session.downloadFolder(
                request.sourcePath, into: URL(fileURLWithPath: destination), entries: entries, progress: progress
            )
        case (.upload, false):
            let size = TransferIOInfo.size(of: request.sourcePath)
            events(.prepared(totalBytes: size, files: 1))
            try await session.upload(URL(fileURLWithPath: request.sourcePath), to: destination, progress: progress)
            var result = FolderTransferResult()
            result.copied = 1
            return result
        case (.upload, true):
            let root = URL(fileURLWithPath: request.sourcePath)
            let entries = try TransferIO.walkLocal(root)
            let files = entries.filter { !$0.isDirectory }
            events(.prepared(totalBytes: files.reduce(0) { $0 + $1.size }, files: files.count))
            return try await session.uploadFolder(root, to: destination, entries: entries, progress: progress)
        }
    }

    func remoteExists(serial: String, path: String) async throws -> Bool {
        try await client(serial).lstat(path).errorCode == 0
    }
}

enum TransferIOInfo {
    static func size(of path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
