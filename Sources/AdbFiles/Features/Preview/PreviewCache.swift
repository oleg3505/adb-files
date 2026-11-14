import AdbKit
import Foundation

/// Local copies of remote files for Quick Look: `<root>/<serial>/<key>/<name>`.
///
/// The key covers path, size and mtime, so a changed file gets a new folder; the original name keeps the
/// extension (Quick Look picks the viewer by it) and the panel title. The whole cache is cleared at launch.
struct PreviewCache: Sendable {
    let directory: URL

    init(serial: String, root: URL = PreviewCache.defaultRoot) {
        let safe = serial.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        directory = root.appendingPathComponent(String(safe), isDirectory: true)
    }

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("AdbFiles/preview", isDirectory: true)
    }

    /// Where the copy of `file` lives (whether or not it was downloaded yet).
    func url(for file: RemoteFile) -> URL {
        directory
            .appendingPathComponent(ThumbnailService.key(for: file), isDirectory: true)
            .appendingPathComponent(file.name)
    }

    /// The local copy when it is complete (same size as on the device), else nil.
    func cachedURL(for file: RemoteFile) -> URL? {
        let url = url(for: file)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.uint64Value == file.size ? url : nil
    }

    /// Creates the folder for `file`'s copy.
    func prepare(for file: RemoteFile) throws {
        try FileManager.default.createDirectory(at: url(for: file).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Removes every cached preview (called at launch, off the main thread).
    static func clearAll(root: URL = PreviewCache.defaultRoot) {
        try? FileManager.default.removeItem(at: root)
    }
}
