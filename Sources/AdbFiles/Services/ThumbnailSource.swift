import AdbKit
import Foundation

/// Reads file bytes for thumbnails. An adapter over the interactive connection in production, a fake in tests.
protocol ThumbnailSource: Sendable {
    /// At most `maxBytes` from the start of the file.
    func read(_ path: String, maxBytes: Int) async throws -> Data
}

/// Reads through the device's interactive connection at `.normal` priority (Quick Look goes first).
struct InteractiveThumbnailSource: ThumbnailSource {
    let client: AdbSyncClient

    func read(_ path: String, maxBytes: Int) async throws -> Data {
        let session = try await client.openInteractiveSession(priority: .normal)
        do {
            let data = try await session.readPrefix(path, maxBytes: maxBytes)
            await session.close()
            return data
        } catch {
            await session.close()
            throw error
        }
    }
}

/// How to get a thumbnail for a file.
enum ThumbnailStrategy: Equatable, Sendable {
    /// Read the first bytes and use the embedded EXIF thumbnail; if there is none, read the whole file when allowed.
    case embedded(prefixBytes: Int, fallbackToFull: Bool)
    /// Read the whole (small) file and scale it.
    case full
    /// Keep the system icon.
    case none

    static let prefixBytes = 64 * 1024
    static let fullReadLimit: UInt64 = 10 * 1024 * 1024

    static func choose(for file: RemoteFile) -> ThumbnailStrategy {
        guard !file.isDirectory, !file.isSymlink, !file.hasError else { return .none }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let small = file.size <= fullReadLimit
        switch ext {
        case "jpg", "jpeg", "heic", "heif": return .embedded(prefixBytes: prefixBytes, fallbackToFull: small)
        case "png", "webp", "gif", "bmp": return small ? .full : .none
        default: return .none
        }
    }
}
