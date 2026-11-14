import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

/// Scripted file operations. Every call can be held at `gate` until the test opens it.
final class FakeOperations: FileOperating {
    private struct State {
        var calls: [String] = []
        var renameError: AdbError?
        var mkdirError: AdbError?
        var failing: [String: AdbError] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let gate: Gate?

    init(gate: Gate? = nil) { self.gate = gate }

    var calls: [String] { state.withLock { $0.calls } }
    func failRename(_ error: AdbError) { state.withLock { $0.renameError = error } }
    func failMkdir(_ error: AdbError) { state.withLock { $0.mkdirError = error } }
    func fail(_ path: String, _ error: AdbError) { state.withLock { $0.failing[path] = error } }

    private func record(_ call: String) async {
        state.withLock { $0.calls.append(call) }
        await gate?.wait()
    }

    func rename(_ path: String, to newName: String) async throws -> String {
        await record("rename \(path) -> \(newName)")
        if let error = state.withLock({ $0.renameError }) { throw error }
        return RemotePath.join(RemotePath.parent(of: path) ?? "/", newName)
    }

    func move(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>] {
        await record("move \(paths.joined(separator: ",")) -> \(folder)")
        return results(paths, folder)
    }

    func copy(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>] {
        await record("copy \(paths.joined(separator: ",")) -> \(folder)")
        return results(paths, folder)
    }

    func delete(_ paths: [String]) async -> [String: Result<Void, AdbError>] {
        await record("delete \(paths.joined(separator: ","))")
        let failing = state.withLock { $0.failing }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, failing[$0].map { .failure($0) } ?? .success(())) })
    }

    func makeDirectory(_ path: String) async throws {
        await record("mkdir \(path)")
        if let error = state.withLock({ $0.mkdirError }) { throw error }
    }

    private func results(_ paths: [String], _ folder: String) -> [String: Result<String, AdbError>] {
        let failing = state.withLock { $0.failing }
        return Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, failing[path].map { .failure($0) } ?? .success(RemotePath.join(folder, (path as NSString).lastPathComponent)))
        })
    }
}

@Suite("Browser file operations")
@MainActor
struct FileOperationsStoreTests {
    private func makeStore(_ listing: FakeListing, ops: FakeOperations, cache: ListingCache = ListingCache()) -> BrowserStore {
        BrowserStore(serial: "A", listing: listing, cache: cache, operations: ops)
    }

    private func loaded(_ files: [RemoteFile], ops: FakeOperations, cache: ListingCache = ListingCache()) async throws -> (BrowserStore, FakeListing) {
        let listing = FakeListing()
        listing.script("/sdcard", .success(files))
        let store = makeStore(listing, ops: ops, cache: cache)
        store.start()
        try await waitUntil { store.phase == .loaded || store.phase == .empty }
        return (store, listing)
    }

    @Test(arguments: [("", "empty"), ("a/b", "/"), (".", "reserved"), ("..", "reserved"), (String(repeating: "я", count: 200), "too long")])
    func invalidNamesAreRefused(name: String, fragment: String) async throws {
        let ops = FakeOperations()
        let (store, _) = try await loaded([file("a.txt")], ops: ops)
        store.commitRename("/sdcard/a.txt", to: name)
        #expect(store.alert?.message.contains(fragment) == true, "\(String(describing: store.alert))")
        #expect(ops.calls.isEmpty)
    }

    @Test func clashIsCaseInsensitiveAndSameNameIsANoOp() async throws {
        let ops = FakeOperations()
        let (store, _) = try await loaded([file("a.txt"), file("B.txt")], ops: ops)
        store.commitRename("/sdcard/a.txt", to: "b.txt")
        #expect(store.alert?.message == "An item named “b.txt” already exists here.")
        store.alert = nil
        store.commitRename("/sdcard/a.txt", to: "a.txt")
        #expect(store.alert == nil)
        #expect(ops.calls.isEmpty)
    }

    @Test func caseOnlyRenameOfTheSameItemIsAllowed() async throws {
        let ops = FakeOperations()
        let (store, _) = try await loaded([file("a.txt")], ops: ops)
        store.commitRename("/sdcard/a.txt", to: "A.txt")
        try await waitUntil { store.busy == nil && !ops.calls.isEmpty }
        #expect(ops.calls == ["rename /sdcard/a.txt -> A.txt"])
    }

    @Test func renameSelectsTheNewPathAndRefreshes() async throws {
        let ops = FakeOperations()
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("a.txt")]), .success([file("b.txt")]))
        let store = makeStore(listing, ops: ops)
        store.start()
        try await waitUntil { store.phase == .loaded }
        store.commitRename("/sdcard/a.txt", to: "b.txt")
        try await waitUntil { store.rows.map(\.name) == ["b.txt"] }
        #expect(store.selection == ["/sdcard/b.txt"])
        #expect(store.busy == nil)
    }

    @Test func newFolderNumbersCaseInsensitivelyAndStartsEditing() async throws {
        let ops = FakeOperations()
        let before = [file("Untitled Folder", folder: true), file("untitled folder 2", folder: true)]
        let listing = FakeListing()
        // The refresh after mkdir returns the new folder, as the device would.
        listing.script("/sdcard", .success(before), .success(before + [file("untitled folder 3", folder: true)]))
        let store = makeStore(listing, ops: ops)
        store.start()
        try await waitUntil { store.phase == .loaded }
        store.newFolder()
        try await waitUntil { store.busy == nil && store.rows.count == 3 }
        #expect(ops.calls == ["mkdir /sdcard/untitled folder 3"])
        #expect(store.editingPath == "/sdcard/untitled folder 3")
        #expect(store.selection == ["/sdcard/untitled folder 3"])
    }

    @Test func deleteListsFailedItemsInTheAlert() async throws {
        let ops = FakeOperations()
        ops.fail("/sdcard/b", .operationFailed("rm: /sdcard/b: Permission denied"))
        let (store, _) = try await loaded([file("a"), file("b"), file("c")], ops: ops)
        store.delete(["/sdcard/a", "/sdcard/b", "/sdcard/c"])
        try await waitUntil { store.alert != nil }
        #expect(store.alert?.title == "Couldn’t delete 1 item")
        #expect(store.alert?.message == "“b”: rm: /sdcard/b: Permission denied")
        #expect(store.busy == nil)
    }

    @Test func moveInvalidatesSourceAndDestination() async throws {
        let cache = ListingCache()
        await cache.store([file("x", in: "/sdcard/Dst")], serial: "A", path: "/sdcard/Dst")
        let ops = FakeOperations()
        let (store, _) = try await loaded([file("a"), file("Dst", folder: true)], ops: ops, cache: cache)
        store.transfer(["/sdcard/a"], into: "/sdcard/Dst", copy: false)
        try await waitUntil { store.busy == nil }
        #expect(await cache.cached(serial: "A", path: "/sdcard/Dst") == nil)
        #expect(ops.calls == ["move /sdcard/a -> /sdcard/Dst"])
    }

    @Test func failureAfterNavigatingAwayStillAlertsAndInvalidates() async throws {
        let gate = Gate()
        let ops = FakeOperations(gate: gate)
        ops.fail("/sdcard/a", .operationFailed("mv: /sdcard/a: Permission denied"))
        let cache = ListingCache()
        let (store, listing) = try await loaded([file("a"), file("Dst", folder: true)], ops: ops, cache: cache)
        listing.script("/sdcard/Other", .success([file("o", in: "/sdcard/Other")]))
        await cache.store([file("x", in: "/sdcard/Dst")], serial: "A", path: "/sdcard/Dst")
        store.transfer(["/sdcard/a"], into: "/sdcard/Dst", copy: false)
        try await waitUntil { !ops.calls.isEmpty }
        store.navigate(to: "/sdcard/Other")
        try await waitUntil { store.path == "/sdcard/Other" && store.phase == .loaded }
        await gate.open()
        try await waitUntil { store.alert != nil }
        #expect(store.alert?.message == "“a”: mv: /sdcard/a: Permission denied")
        #expect(await cache.cached(serial: "A", path: "/sdcard/Dst") == nil)
        #expect(await cache.cached(serial: "A", path: "/sdcard") == nil)
        #expect(store.path == "/sdcard/Other")
        #expect(store.busy == nil)
    }

    @Test func aSecondOperationWhileBusyIsRefused() async throws {
        let gate = Gate()
        let ops = FakeOperations(gate: gate)
        let (store, _) = try await loaded([file("a"), file("b")], ops: ops)
        store.delete(["/sdcard/a"])
        try await waitUntil { ops.calls.count == 1 }
        #expect(!store.canOperate)
        store.delete(["/sdcard/b"])
        store.newFolder()
        store.beginRename("/sdcard/b")
        #expect(store.editingPath == nil)
        await gate.open()
        try await waitUntil { store.busy == nil }
        #expect(ops.calls == ["delete /sdcard/a"])
    }

    @Test func renameEditingLifecycle() async throws {
        let ops = FakeOperations()
        let (store, _) = try await loaded([file("a")], ops: ops)
        store.beginRename("/sdcard/a")
        #expect(store.editingPath == "/sdcard/a")
        store.cancelRename()
        #expect(store.editingPath == nil)
        #expect(ops.calls.isEmpty)
    }

    @Test func refreshWithoutCacheKeepsRowsVisible() async throws {
        let listing = FakeListing()
        listing.script("/sdcard", .success([file("a"), file("b")]))
        let cache = ListingCache()
        let store = BrowserStore(serial: "A", listing: listing, cache: cache, operations: FakeOperations())
        store.start()
        try await waitUntil { store.phase == .loaded }
        await cache.remove(serial: "A", path: "/sdcard") // what an operation does
        listing.gate("/sdcard")
        store.refresh()
        try await waitUntil { listing.calls.count == 2 }
        #expect(store.phase == .loaded, "no spinner while reloading the same folder")
        #expect(store.rows.map(\.name) == ["a", "b"])
        listing.release("/sdcard")
    }

    @Test func copyPathsOnePerLine() async throws {
        let (store, _) = try await loaded([file("a")], ops: FakeOperations())
        #expect(store.pathsText(["/sdcard/a", "/sdcard/Б в.txt"]) == "/sdcard/a\n/sdcard/Б в.txt")
    }
}
