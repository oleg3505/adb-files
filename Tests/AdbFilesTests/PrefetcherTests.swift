import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

/// A sleep that ends only when the test calls `elapse()`; cancelling the sleeper ends it with an error.
final class ManualSleeper: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UUID: CheckedContinuation<Void, Error>]())

    var pending: Int { state.withLock { $0.count } }

    var sleep: Prefetcher.Sleep {
        { [state] _ in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled = state.withLock { s -> Bool in
                        if Task.isCancelled { return true }
                        s[id] = continuation
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                state.withLock { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }
    }

    /// The delay has passed for every waiting sleep.
    func elapse() {
        let all = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            defer { s.removeAll() }
            return Array(s.values)
        }
        all.forEach { $0.resume() }
    }
}

@MainActor
@Suite struct PrefetcherTests {
    let listing = FakeListing()
    let cache = ListingCache()
    let sleeper = ManualSleeper()

    private func makePrefetcher() -> Prefetcher {
        Prefetcher(serial: "A", listing: listing, cache: cache, sleep: sleeper.sleep)
    }

    @Test func leavingBeforeTheDelayListsNothing() async throws {
        let prefetcher = makePrefetcher()
        prefetcher.request("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        prefetcher.request(nil)
        try await waitUntil { sleeper.pending == 0 }
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(30))
        #expect(listing.calls.isEmpty)
    }

    @Test func restingOnAFolderListsItOnceIntoTheCache() async throws {
        listing.script("/sdcard/DCIM", .success([file("Camera", in: "/sdcard/DCIM", folder: true)]))
        let prefetcher = makePrefetcher()
        prefetcher.request("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await waitUntil { prefetcher.isFresh("/sdcard/DCIM") }
        #expect(listing.calls == ["/sdcard/DCIM"])
        #expect(await cache.cached(serial: "A", path: "/sdcard/DCIM")?.map(\.name) == ["Camera"])
    }

    @Test func movingQuicklyOverFoldersListsOnlyTheLastOne() async throws {
        let prefetcher = makePrefetcher()
        prefetcher.request("/sdcard/A")
        prefetcher.request("/sdcard/B")
        prefetcher.request("/sdcard/C")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await waitUntil { listing.calls.count == 1 }
        #expect(listing.calls == ["/sdcard/C"])
    }

    @Test func cachedFolderIsNotListedAgain() async throws {
        await cache.store([file("x")], serial: "A", path: "/sdcard/DCIM")
        let prefetcher = makePrefetcher()
        prefetcher.request("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(30))
        #expect(listing.calls.isEmpty)
    }
}

@MainActor
@Suite struct BrowserPrefetchTests {
    let listing = FakeListing()
    let sleeper = ManualSleeper()

    private func startedStore() async throws -> BrowserStore {
        let store = BrowserStore(serial: "A", listing: listing, cache: ListingCache(), prefetchSleep: sleeper.sleep)
        store.start()
        try await waitUntil { store.phase == .loaded || store.phase == .empty }
        return store
    }

    @Test func openingAPrefetchedFolderShowsTheCacheWithoutASecondListing() async throws {
        listing.script("/sdcard/DCIM", .success([file("Camera", in: "/sdcard/DCIM", folder: true)]))
        let store = try await startedStore()
        store.prefetch("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await waitUntil { listing.calls.contains("/sdcard/DCIM") }
        try await Task.sleep(for: .milliseconds(30))
        store.navigate(to: "/sdcard/DCIM", action: "open")
        try await waitUntil { store.rows.map(\.name) == ["Camera"] }
        try await Task.sleep(for: .milliseconds(30))
        #expect(listing.calls.filter { $0 == "/sdcard/DCIM" }.count == 1)
    }

    @Test func openingTheFolderWhileItsPrefetchRunsReusesIt() async throws {
        listing.script("/sdcard/DCIM", .success([file("Camera", in: "/sdcard/DCIM", folder: true)]))
        listing.gate("/sdcard/DCIM")
        let store = try await startedStore()
        store.prefetch("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await waitUntil { listing.calls.contains("/sdcard/DCIM") }
        store.navigate(to: "/sdcard/DCIM", action: "open")
        listing.release("/sdcard/DCIM")
        try await waitUntil { store.rows.map(\.name) == ["Camera"] }
        #expect(listing.calls.filter { $0 == "/sdcard/DCIM" }.count == 1, "the running prefetch is awaited, not repeated")
    }

    @Test func openingAnotherFolderCancelsThePrefetchFirst() async throws {
        listing.gateCancellable("/sdcard/DCIM")
        listing.script("/sdcard/Music", .success([file("song.mp3", in: "/sdcard/Music")]))
        let store = try await startedStore()
        store.prefetch("/sdcard/DCIM")
        try await waitUntil { sleeper.pending == 1 }
        sleeper.elapse()
        try await waitUntil { listing.calls.contains("/sdcard/DCIM") }
        store.navigate(to: "/sdcard/Music", action: "open")
        // The gated prefetch was cancelled, so Music lists without waiting for DCIM.
        try await waitUntil { store.rows.map(\.name) == ["song.mp3"] }
        #expect(listing.cancelledCalls.contains("/sdcard/DCIM"))
    }
}
