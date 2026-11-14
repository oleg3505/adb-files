import Foundation

/// A file or directory entry on the device, from a sync `LIST`/`LIS2` reply.
public struct RemoteFile: Sendable, Hashable, Identifiable {
    /// Entry name (last path component), UTF-8 decoded.
    public let name: String
    /// Absolute path on the device, without a trailing slash (except `/`).
    public let path: String
    /// POSIX mode bits (type + permissions).
    public let mode: UInt32
    /// Size in bytes; 64-bit with `ls_v2`, otherwise at most 4 GiB.
    public let size: UInt64
    /// Last modification time; nil when the device could not stat the entry.
    public let modificationDate: Date?
    /// Raw errno reported by the device for this entry (`LIS2` only); 0 means no error.
    public let errorCode: UInt32

    /// Creates an entry.
    public init(name: String, path: String, mode: UInt32, size: UInt64, modificationDate: Date?, errorCode: UInt32 = 0) {
        self.name = name
        self.path = path
        self.mode = mode
        self.size = size
        self.modificationDate = modificationDate
        self.errorCode = errorCode
    }

    /// Stable identity: the path.
    public var id: String { path }

    private var fileType: UInt32 { mode & 0o170000 }
    /// Whether this is a directory.
    public var isDirectory: Bool { fileType == 0o040000 }
    /// Whether this is a symbolic link (not followed).
    public var isSymlink: Bool { fileType == 0o120000 }
    /// Whether the name starts with a dot.
    public var isHidden: Bool { name.hasPrefix(".") }
    /// Whether the device failed to stat this entry, so size and date are unknown.
    public var hasError: Bool { errorCode != 0 }
}

/// Helpers for absolute POSIX paths on the device.
public enum RemotePath {
    /// Joins a directory and an entry name.
    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : normalized(directory) + "/" + name
    }

    /// Removes trailing slashes, keeping `/` for the root.
    public static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// The path to send in a listing request: always ends with `/`, so symlinked directories
    /// such as `/sdcard` are followed.
    public static func listingPath(_ directory: String) -> String {
        let path = normalized(directory)
        return path == "/" ? "/" : path + "/"
    }

    /// The parent directory, or nil for `/`.
    public static func parent(of path: String) -> String? {
        let path = normalized(path)
        guard path != "/" else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// Path components from the root, e.g. `/sdcard/DCIM` → `["sdcard", "DCIM"]`.
    public static func components(_ path: String) -> [String] {
        normalized(path).split(separator: "/").map(String.init)
    }
}
