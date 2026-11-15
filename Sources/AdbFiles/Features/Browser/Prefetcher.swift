import AdbKit
import Foundation
import os

/// Lists a folder in the background while the pointer rests on its row (or it is selected) for 150 ms, so opening
/// it is instant (CLAUDE.md § Performance: prefetch).
///
/// One target at a time: a new target cancels the previous one. The listing connection is shared with
/// navigation, so the browser either reuses an in-flight prefetch of the folder it opens (`take`) or cancels it
/// first (`cancel`) — a prefetch never delays opening another folder.
@MainActor
final class Prefetcher {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let serial: String
    private let listing: any DirectoryListing
    private let cache: ListingCache
    private let delay: Duration
    private let sleep: Sleep
    private let signposter = OSSignposter(logger: .ui)

    /// The folder asked for (pointer or selection), waiting out the delay or being listed.
    private(set) var target: String?
    private var debounce: Task<Void, Never>?
    private var listingTask: (path: String, task: Task<[RemoteFile]?, Never>)?
    /// When each folder was last prefetched, so the browser can skip an immediate second listing.
    private var fetchedAt: [String: ContinuousClock.Instant] = [:]

    init(
        serial: String, listing: any DirectoryListing, cache: ListingCache, delay: Duration = .milliseconds(150),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.serial = serial
        self.listing = listing
        self.cache = cache
        self.delay = delay
        self.sleep = sleep
    }

    /// The pointer rests on (or the selection is) the folder at `path`; nil when it left every folder row.
    func request(_ path: String?) {
        guard path != target else { return }
        target = path
        debounce?.cancel()
        debounce = nil
        guard let path else { return }
        debounce = Task { [weak self, sleep, delay] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.start(path)
        }
    }

    /// The browser opens `path`: the in-flight prefetch of it, if any (its result is nil when it failed). Any other
    /// prefetch is cancelled so the listing connection is free.
    func take(_ path: String) -> Task<[RemoteFile]?, Never>? {
        debounce?.cancel()
        debounce = nil
        target = nil
        if let running = listingTask, running.path == path {
            listingTask = nil
            return running.task
        }
        cancel()
        return nil
    }

    /// Whether `path` was prefetched within `window` (its cached listing is fresh).
    func isFresh(_ path: String, within window: Duration = .seconds(10)) -> Bool {
        guard let at = fetchedAt[path] else { return false }
        return ContinuousClock.now - at < window
    }

    /// Stops everything (navigation elsewhere, browser closed).
    func cancel() {
        debounce?.cancel()
        debounce = nil
        target = nil
        if let running = listingTask {
            running.task.cancel()
            Logger.ui.info("prefetch cancel path=\(running.path, privacy: .public)")
        }
        listingTask = nil
    }

    private func start(_ path: String) async {
        guard target == path else { return }
        if await cache.cached(serial: serial, path: path) != nil { return } // already known: nothing to gain
        guard target == path, listingTask?.path != path else { return }
        listingTask?.task.cancel()
        let listing = self.listing
        let cache = self.cache
        let serial = self.serial
        let signposter = self.signposter
        let task = Task<[RemoteFile]?, Never>(priority: .utility) {
            let interval = signposter.beginInterval("prefetch", id: signposter.makeSignpostID(), "\(path, privacy: .public)")
            defer { signposter.endInterval("prefetch", interval) }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let files = try await listing.list(path)
                try Task.checkCancellation()
                await cache.store(files, serial: serial, path: path)
                let ms = Int((clock.now - started) / .milliseconds(1))
                Logger.ui.info("prefetch done path=\(path, privacy: .public) entries=\(files.count) ms=\(ms)")
                return files
            } catch {
                return nil
            }
        }
        listingTask = (path, task)
        Logger.ui.info("prefetch start path=\(path, privacy: .public)")
        if await task.value != nil { fetchedAt[path] = .now }
        if listingTask?.path == path, listingTask?.task == task { listingTask = nil }
    }
}
