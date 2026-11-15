import Foundation
import os

/// Keeps the thumbnail disk cache bounded: at launch, above `limit` bytes it deletes the oldest thumbnails (by
/// modification date, i.e. when they were generated) until the cache is at most `target` bytes.
enum ThumbnailCacheTrimmer {
    static let limit: Int64 = 500 * 1024 * 1024
    static let target: Int64 = 400 * 1024 * 1024

    struct Result: Equatable {
        let before: Int64
        let after: Int64
        let removed: Int
    }

    /// Synchronous file work: call it off the main thread.
    @discardableResult
    static func trim(root: URL = ThumbnailService.defaultCacheRoot, limit: Int64 = limit, target: Int64 = target) -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return Result(before: 0, after: 0, removed: 0)
        }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        let before = files.reduce(0) { $0 + $1.size }
        guard before > limit else {
            Logger.ui.info("thumb cache size=\(before) files=\(files.count)")
            return Result(before: before, after: before, removed: 0)
        }
        var total = before
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) where total > target {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        Logger.ui.info("thumb trim before=\(before) after=\(total) removed=\(removed)")
        return Result(before: before, after: total, removed: removed)
    }
}
