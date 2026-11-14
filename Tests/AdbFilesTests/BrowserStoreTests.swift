import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

// MARK: - Fake

/// Scripted listings. A gated path suspends `list` until the test calls `release(_:)`.
final class FakeListing: DirectoryListing {
    private struct State {
        var results: [String: [Result<[RemoteFile], AdbError>]] = [:]
        var calls: [String] = []
        var gated: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var disconnects = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Queues results for `path`; the last one repeats.
    func script(_ path: String, _ results: Result<[RemoteFile], AdbError>...) {
        state.withLock { $0.results[path, default: []].append(contentsOf: results) }
    }

    func gate(_ path: String) { state.withLock { _ = $0.gated.insert(path) } }

    func release(_ path: String) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.gated.remove(path)
            return state.waiting.removeValue(forKey: path) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    var calls: [String] { state.withLock { $0.calls } }
    var disconnects: Int { state.withLock { $0.disconnects } }

    func list(_ directory: String) async throws -> [RemoteFile] {
        let gated = state.withLock { state -> Bool in
            state.calls.append(directory)
            return state.gated.contains(directory)
        }
        if gated {
            await withCheckedContinuation { continuation in
                state.withLock { $0.waiting[directory, default: []].append(continuation) }
            }
        }
        let result: Result<[RemoteFile], AdbError> = state.withLock { state in
            guard var queue = state.results[directory], !queue.isEmpty else { return .success([]) }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            state.results[directory] = queue
            return next
        }
        return try result.get()
    }

    func disconnect() async { state.withLock { $0.disconnects += 1 } }
}

func file(_ name: String, in directory: String = "/sdcard", folder: Bool = false, size: UInt64 = 1, mtime: TimeInterval = 0) -> RemoteFile {
    RemoteFile(
        name: name, path: RemotePath.join(directory, name), mode: folder ? 0o40770 : 0o100660, size: size,
        modificationDate: Date(timeIntervalSince1970: mtime)
    )
}

// MARK: - Tests

@Suite("BrowserStore")
@MainActor
struct BrowserStoreTests {
    private func makeStore(_ listing: FakeListing, cache: ListingCache = ListingCache(), serial: String = "A") -> BrowserStore {
        BrowserStore(serial: serial, listing: listing, cache: cache)
    }

    @Test func startsAtInternalStorageWithFoldersFirst() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("b.txt"), file("Music", folder: true), file("a.txt"), file("DCIM", folder: true)]))
        let store = makeStore(listing)
        store.start()
        try await waitUntil { store.phase == .loaded }
        #expect(store.path == "/sdcard")
        #expect(store.rows.map(\.name) == ["DCIM", "Music", "a.txt", "b.txt"])
        #expect(listing.calls == ["/sdcard"])
    }

    @Test func backForwardAndUpFollowFinderSemantics() async throws {
        let listing = FakeListing()
        let store = makeStore(listing)
        store.start()
        store.navigate(to: "/sdcard/DCIM")
        store.navigate(to: "/sdcard/DCIM/Camera")
        store.goBack()
        #expect(store.path == "/sdcard/DCIM")
        store.goBack()
        #expect(store.path == "/sdcard")
        #expect(!store.canGoBack && store.canGoForward)
        store.goForward()
        #expect(store.path == "/sdcard/DCIM")
        store.navigate(to: "/sdcard/DCIM/Screenshots")
        #expect(!store.canGoForward, "a new navigation clears Forward")
        store.goUp()
        #expect(store.path == "/sdcard/DCIM")
        store.goBack()
        #expect(store.path == "/sdcard/DCIM/Screenshots", "Up is a navigation, so Back returns from it")
        store.navigate(to: "/")
        #expect(!store.canGoUp)
    }

    @Test func cachedListingShowsBeforeTheRefreshCompletes() async throws {
        let listing = FakeListing()
        listing.script("/sdcard/DCIM", .success([file("Camera", in: "/sdcard/DCIM", folder: true)]))
        let cache = ListingCache()
        let store = makeStore(listing, cache: cache)
        store.start()
        store.navigate(to: "/sdcard/DCIM")
        try await waitUntil { store.phase == .loaded && store.path == "/sdcard/DCIM" }
        store.goBack()
        try await waitUntil { store.path == "/sdcard" && store.phase == .empty }

        listing.gate("/sdcard/DCIM")
        store.goForward()
        // The store shows the cache first, then asks the device: the second request means the cache is on screen.
        try await waitUntil { listing.calls.filter { $0 == "/sdcard/DCIM" }.count == 2 }
        #expect(store.rows.map(\.name) == ["Camera"])
        #expect(store.phase == .loaded, "cached rows are shown while the device listing is still pending")
        let versionWithCache = store.rowsVersion
        listing.release("/sdcard/DCIM")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.rowsVersion == versionWithCache, "an unchanged refresh does not reload the table")
    }

    @Test func changedRefreshKeepsSelectionByName() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("a"), file("b")]), .success([file("b"), file("c")]))
        let store = makeStore(listing)
        store.start()
        try await waitUntil { store.rows.count == 2 }
        store.setSelection(["/sdcard/b", "/sdcard/a"])
        store.refresh()
        try await waitUntil { store.rows.map(\.name) == ["b", "c"] }
        #expect(store.selection == ["/sdcard/b"])
    }

    @Test func hiddenFilesToggle() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file(".thumbnails", folder: true), file("photo.jpg")]))
        let store = makeStore(listing)
        store.start()
        try await waitUntil { store.phase == .loaded }
        #expect(store.rows.map(\.name) == ["photo.jpg"])
        store.showHidden = true
        try await waitUntil { store.rows.count == 2 }
        #expect(store.rows.map(\.name) == [".thumbnails", "photo.jpg"])
    }

    @Test(arguments: [
        (AdbError.permissionDenied("/sdcard"), BrowserStore.Phase.denied),
        (AdbError.notFound("/sdcard"), BrowserStore.Phase.notFound),
        (AdbError.notADirectory("/sdcard"), BrowserStore.Phase.notFound),
        (AdbError.timeout, BrowserStore.Phase.failed(AdbError.timeout.localizedDescription)),
    ])
    func errorsMapToPhases(error: AdbError, phase: BrowserStore.Phase) async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .failure(error))
        let store = makeStore(listing)
        store.start()
        try await waitUntil { store.phase == phase }
        #expect(store.rows.isEmpty)
    }

    @Test func emptyFolderPhase() async throws {
        let store = makeStore(FakeListing())
        store.start()
        try await waitUntil { store.phase == .empty }
    }

    @Test func staleResultAfterNavigatingAwayIsDiscarded() async throws {
        let listing = FakeListing()
        listing.script("/sdcard/slow", .success([file("old", in: "/sdcard/slow")]))
        listing.script("/sdcard/fast", .success([file("new", in: "/sdcard/fast")]))
        listing.gate("/sdcard/slow")
        let store = makeStore(listing)
        store.navigate(to: "/sdcard/slow")
        try await waitUntil { listing.calls.contains("/sdcard/slow") }
        store.navigate(to: "/sdcard/fast")
        try await waitUntil { store.rows.map(\.name) == ["new"] }
        listing.release("/sdcard/slow")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.rows.map(\.name) == ["new"])
        #expect(store.path == "/sdcard/fast")
    }

    @Test func cancelMidListingWritesNothingAfterwards() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("late")]))
        listing.gate("/sdcard")
        let store = makeStore(listing)
        store.start()
        try await waitUntil { listing.calls == ["/sdcard"] }
        let version = store.rowsVersion
        store.cancel(reason: "device-gone")
        listing.release("/sdcard")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.rows.isEmpty)
        #expect(store.rowsVersion == version)
        #expect(store.phase == .loading)
    }

    @Test func eachDeviceHasItsOwnCacheAndStartsAtInternalStorage() async throws {
        let cache = ListingCache()
        await cache.store([file("fromA")], serial: "A", path: "/sdcard")
        let listing = FakeListing()
        listing.gate("/sdcard")
        let store = makeStore(listing, cache: cache, serial: "B")
        store.start()
        try await waitUntil { listing.calls == ["/sdcard"] }
        #expect(store.path == "/sdcard")
        #expect(store.rows.isEmpty, "device B must not show device A's cached listing")
        #expect(store.phase == .loading)
        listing.release("/sdcard")
    }

    @Test func symlinkRowIsAnAliasAndOpensAsFolder() async throws {
        let link = RemoteFile(name: "sdcard", path: "/sdcard", mode: 0o120777, size: 21, modificationDate: nil)
        let listing = FakeListing()
        listing.script("/", .success([link]))
        let store = BrowserStore(serial: "A", listing: listing, cache: ListingCache(), startPath: "/")
        store.start()
        try await waitUntil { store.phase == .loaded }
        let row = try #require(store.rows.first)
        #expect(row.kind == "Alias")
        store.open(row)
        try await waitUntil { listing.calls.contains("/sdcard") }
        #expect(store.path == "/sdcard")
    }

    @Test func openingAFileDoesNotNavigate() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("a.txt")]))
        let store = makeStore(listing)
        store.start()
        try await waitUntil { store.phase == .loaded }
        store.open(try #require(store.rows.first))
        #expect(store.path == "/sdcard")
    }
}
