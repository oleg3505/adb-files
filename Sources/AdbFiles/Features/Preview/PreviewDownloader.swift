import AdbKit
import Foundation
import os

/// Downloads one file for Quick Look. The interactive connection in production, a fake in tests.
protocol PreviewDownloading: Sendable {
    func download(_ file: RemoteFile, to url: URL) async throws
}

/// Downloads over the device's interactive connection at `.high` priority, so a preview never waits behind
/// thumbnail reads (and never behind transfers, which have their own connections).
struct InteractivePreviewDownloader: PreviewDownloading {
    let client: AdbSyncClient
    private static let signposter = OSSignposter(logger: .ui)

    func download(_ file: RemoteFile, to url: URL) async throws {
        let interval = Self.signposter.beginInterval("preview", id: Self.signposter.makeSignpostID(), "\(file.name, privacy: .public)")
        defer { Self.signposter.endInterval("preview", interval) }
        let clock = ContinuousClock()
        let started = clock.now
        let session = try await client.openInteractiveSession(priority: .high)
        Logger.ui.info("preview wait ms=\(Int((clock.now - started) / .milliseconds(1)))")
        do {
            try await session.download(file.path, to: url, modificationDate: file.modificationDate, overwrite: true) { _ in }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}
