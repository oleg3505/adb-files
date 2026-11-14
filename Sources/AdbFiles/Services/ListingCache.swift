import AdbKit

/// In-memory directory listings for this app session, keyed by device and path.
///
/// Used for stale-while-revalidate: show the cached listing at once, refresh in the background, and
/// reload the table only when the fresh listing differs.
actor ListingCache {
    struct Key: Hashable, Sendable {
        let serial: String
        let path: String
    }

    private var listings: [Key: [RemoteFile]] = [:]

    func cached(serial: String, path: String) -> [RemoteFile]? {
        listings[Key(serial: serial, path: path)]
    }

    /// Stores a fresh listing. Returns whether it differs from the previous one (ignoring order).
    @discardableResult
    func store(_ files: [RemoteFile], serial: String, path: String) -> Bool {
        let key = Key(serial: serial, path: path)
        let previous = listings[key]
        listings[key] = files
        guard let previous else { return true }
        return previous.count != files.count || Set(previous) != Set(files)
    }

    func remove(serial: String, path: String) {
        listings[Key(serial: serial, path: path)] = nil
    }

    /// Removes `path` and every cached folder below it.
    func removeTree(serial: String, path: String) {
        let prefix = path == "/" ? "/" : path + "/"
        listings = listings.filter { key, _ in key.serial != serial || (key.path != path && !key.path.hasPrefix(prefix)) }
    }
}
