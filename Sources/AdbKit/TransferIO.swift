import Foundation

/// File-system helpers for transfers on the Mac side.
public enum TransferIO {
    /// Suffix of the temporary file a download writes before it is moved into place.
    public static let partSuffix = ".adbfiles-part"

    /// The temporary file for a download target: `name.ext.adbfiles-part` next to it.
    public static func temporaryURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + partSuffix)
    }

    /// Moves `source` to `target` without ever replacing an existing file.
    /// - Throws: `AdbError.localFileExists` when `target` exists.
    static func moveWithoutOverwrite(_ source: URL, to target: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch CocoaError.fileWriteFileExists {
            throw AdbError.localFileExists(target.path)
        } catch {
            if FileManager.default.fileExists(atPath: target.path) { throw AdbError.localFileExists(target.path) }
            throw AdbError.localIOError(error.localizedDescription)
        }
    }

    /// Sets a file's or folder's modification time.
    static func setModificationDate(_ date: Date, of url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Size and modification time of a local file, if it exists.
    static func fileInfo(_ url: URL) -> (size: UInt64, mtime: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let mtime = attributes[.modificationDate] as? Date else { return nil }
        return (size, mtime)
    }

    /// One entry of a local folder walk.
    public struct LocalEntry: Sendable, Equatable {
        /// Path relative to the walked root, using `/`.
        public let relativePath: String
        public let isDirectory: Bool
        public let size: UInt64
        public let modificationDate: Date
        /// POSIX permission bits.
        public let mode: UInt32
    }

    /// Lists a local folder recursively (folders before their contents); symbolic links are skipped.
    public static func walkLocal(_ root: URL) throws -> [LocalEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw AdbError.localIOError("cannot read \(root.path)")
        }
        let rootPath = root.standardizedFileURL.path
        var entries: [LocalEntry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            entries.append(LocalEntry(
                relativePath: relative, isDirectory: values?.isDirectory ?? false, size: UInt64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate ?? Date(), mode: mode
            ))
        }
        return entries
    }
}

/// Counts of a folder transfer.
public struct FolderTransferResult: Sendable, Equatable {
    public var copied = 0
    public var skipped = 0
    /// Relative paths that failed, with the reason.
    public var failures: [String: String] = [:]

    public init() {}
}

/// A remote entry found by a recursive walk.
public struct RemoteTreeEntry: Sendable, Equatable {
    /// Path relative to the walked root, using `/`.
    public let relativePath: String
    public let file: RemoteFile
}
