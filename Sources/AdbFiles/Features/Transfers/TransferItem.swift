import AdbKit
import Foundation

enum TransferDirection: String, Sendable {
    case download, upload
}

/// What to transfer. `source` and `targetFolder` are remote paths or local file URLs depending on direction.
struct TransferRequest: Sendable, Equatable {
    let direction: TransferDirection
    let serial: String
    /// Download: remote path. Upload: local file path.
    let sourcePath: String
    let isFolder: Bool
    /// Download: local folder. Upload: remote folder.
    let targetFolder: String
    /// Remote size/mtime when known (downloads of single files).
    var size: UInt64 = 0
    var modificationDate: Date?
    /// A name the destination already chose (Finder file promises); skips keep-both renaming.
    var fixedName: String?

    var name: String { fixedName ?? (sourcePath as NSString).lastPathComponent }
}

/// One row in the transfers list.
struct TransferItem: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        case queued
        case preparing
        case running
        case done(copied: Int, skipped: Int)
        case failed(String, retryable: Bool)
        case cancelled

        var isFinal: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            case .queued, .preparing, .running: false
            }
        }

        var isActive: Bool { !isFinal }
    }

    /// Why a transfer was stopped from outside; recorded before its task is cancelled.
    enum StopReason: Sendable, Equatable {
        case user
        case deviceGone
    }

    let id = UUID()
    let request: TransferRequest
    var state: State = .queued
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0
    var fileCount = 1
    /// Bytes per second over the last few seconds.
    var speed: Double = 0
    var eta: Duration?
    /// Final name chosen at the first attempt (keep-both); reused by Retry.
    var resolvedName: String?
    var stopReason: StopReason?
    /// Bumped on every start; events from an older attempt are ignored.
    var attempt = 0
    /// How many times progress was published (evidence for the ≤ 10/s rule).
    var publishes = 0
    var failures: [String: String] = [:]

    var name: String { resolvedName ?? request.name }

    var fractionDone: Double {
        bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal))
    }

    /// Full destination path (local path or remote path).
    var destinationPath: String? {
        guard let resolvedName else { return nil }
        switch request.direction {
        case .download: return (request.targetFolder as NSString).appendingPathComponent(resolvedName)
        case .upload: return RemotePath.join(request.targetFolder, resolvedName)
        }
    }
}
