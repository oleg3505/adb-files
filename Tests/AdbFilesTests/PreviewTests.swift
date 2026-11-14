import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

/// Writes `file.size` bytes for each download; records calls; can hold or fail a path.
final class FakePreviewDownloader: PreviewDownloading {
    private struct State {
        var calls: [String] = []
        var gates: [String: Gate] = [:]
        var failures: [String: AdbError] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A downloader that finishes even when cancelled (to prove the controller drops late results itself).
    let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }

    var calls: [String] { state.withLock { $0.calls } }
    func hold(_ path: String, _ gate: Gate) { state.withLock { $0.gates[path] = gate } }
    func fail(_ path: String, _ error: AdbError) { state.withLock { $0.failures[path] = error } }

    func download(_ file: RemoteFile, to url: URL) async throws {
        let (gate, failure) = state.withLock { state -> (Gate?, AdbError?) in
            state.calls.append(file.path)
            return (state.gates[file.path], state.failures[file.path])
        }
        await gate?.wait()
        if !ignoresCancellation { try Task.checkCancellation() }
        if let failure { throw failure }
        try Data(count: Int(file.size)).write(to: url)
    }
}

@MainActor
final class FakePresenter: PreviewPresenting {
    var isVisible = false
    var shown: [[String]] = []
    var closes = 0

    func show(_ urls: [URL]) {
        shown.append(urls.map(\.lastPathComponent))
        isVisible = true
    }

    func close() {
        closes += 1
        isVisible = false
    }
}

private func remote(_ name: String, size: UInt64 = 10, mtime: TimeInterval = 1_700_000_000, mode: UInt32 = 0o100660) -> RemoteFile {
    RemoteFile(name: name, path: "/sdcard/Download/\(name)", mode: mode, size: size, modificationDate: Date(timeIntervalSince1970: mtime))
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-preview-\(UUID().uuidString)")
}

@Suite struct PreviewCacheTests {
    @Test func keepsTheNameAndChangesFolderWithSizeOrMtime() {
        let cache = PreviewCache(serial: "S:1", root: tempRoot())
        let file = remote("Звіт 🙂.pdf")
        #expect(cache.url(for: file).lastPathComponent == "Звіт 🙂.pdf")
        #expect(cache.url(for: file).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "S_1")
        #expect(cache.url(for: file) != cache.url(for: remote("Звіт 🙂.pdf", size: 11)))
        #expect(cache.url(for: file) != cache.url(for: remote("Звіт 🙂.pdf", mtime: 1)))
    }

    @Test func reusedOnlyWhenComplete() throws {
        let cache = PreviewCache(serial: "S", root: tempRoot())
        let file = remote("a.txt", size: 4)
        #expect(cache.cachedURL(for: file) == nil)
        try cache.prepare(for: file)
        try Data("ab".utf8).write(to: cache.url(for: file))
        #expect(cache.cachedURL(for: file) == nil, "a partial copy is not reused")
        try Data("abcd".utf8).write(to: cache.url(for: file))
        #expect(cache.cachedURL(for: file) == cache.url(for: file))
        #expect(cache.cachedURL(for: remote("a.txt", size: 4, mtime: 5)) == nil, "changed mtime → new copy")
    }

    @Test func clearedAtLaunch() throws {
        let root = tempRoot()
        let cache = PreviewCache(serial: "S", root: root)
        let file = remote("a.txt", size: 1)
        try cache.prepare(for: file)
        try Data("a".utf8).write(to: cache.url(for: file))
        PreviewCache.clearAll(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@MainActor
@Suite struct PreviewControllerTests {
    let downloader: FakePreviewDownloader
    let presenter = FakePresenter()
    let cache = PreviewCache(serial: "S", root: tempRoot())
    let alerts = AlertLog()
    let controller: PreviewController

    final class AlertLog {
        var items: [OperationAlert] = []
    }

    init() { self.init(ignoresCancellation: false) }

    init(ignoresCancellation: Bool) {
        downloader = FakePreviewDownloader(ignoresCancellation: ignoresCancellation)
        let alerts = self.alerts
        controller = PreviewController(cache: cache, downloader: downloader, presenter: presenter) { alerts.items.append($0) }
    }

    @Test func downloadsThenShowsWithASpinnerMeanwhile() async throws {
        let gate = Gate()
        downloader.hold("/sdcard/Download/a.jpg", gate)
        controller.toggle([remote("a.jpg")])
        #expect(controller.loadingName == "a.jpg")
        #expect(presenter.shown.isEmpty)
        await gate.open()
        try await waitUntil { presenter.shown.count == 1 }
        #expect(presenter.shown == [["a.jpg"]])
        #expect(controller.loadingName == nil)
        #expect(alerts.items.isEmpty)
    }

    @Test func foldersAndLinksAreSkipped() {
        controller.toggle([remote("Camera", mode: 0o040770), remote("link", mode: 0o120777)])
        #expect(downloader.calls.isEmpty)
        #expect(!controller.isActive)
    }

    @Test func multiSelectionShowsAllItems() async throws {
        controller.toggle([remote("a.jpg"), remote("Camera", mode: 0o040770), remote("b.pdf"), remote("c.mp4")])
        try await waitUntil { presenter.shown.count == 1 }
        #expect(presenter.shown == [["a.jpg", "b.pdf", "c.mp4"]])
    }

    @Test func secondOpenUsesTheCacheWithoutDownloading() async throws {
        controller.toggle([remote("a.jpg")])
        try await waitUntil { presenter.shown.count == 1 }
        controller.toggle([])
        #expect(presenter.closes == 1 && !controller.isActive)
        controller.toggle([remote("a.jpg")])
        #expect(presenter.shown.count == 2, "shown at once from the cache")
        #expect(downloader.calls == ["/sdcard/Download/a.jpg"])
    }

    @Test func selectionChangeCancelsThePreviousDownloadAndFollows() async throws {
        let gate = Gate()
        downloader.hold("/sdcard/Download/a.mp4", gate)
        controller.toggle([remote("a.mp4")])
        try await waitUntil { downloader.calls.count == 1 }
        controller.selectionChanged([remote("b.jpg")])
        try await waitUntil { presenter.shown.count == 1 }
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(presenter.shown == [["b.jpg"]], "a cancelled download never reaches the panel")
        #expect(alerts.items.isEmpty, "cancellation is not an error")
        #expect(cache.cachedURL(for: remote("a.mp4")) == nil)
    }

    @Test func lateCompletionOfASupersededRequestIsIgnored() async throws {
        let controller = PreviewControllerTests(ignoresCancellation: true)
        let gate = Gate()
        controller.downloader.hold("/sdcard/Download/a.mp4", gate)
        controller.controller.toggle([remote("a.mp4")])
        try await waitUntil { controller.downloader.calls.count == 1 }
        controller.controller.selectionChanged([remote("b.jpg")])
        try await waitUntil { controller.presenter.shown.count == 1 }
        await gate.open() // A finishes after B, despite the cancel
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.presenter.shown == [["b.jpg"]])
        #expect(controller.controller.loadingName == nil)
        #expect(controller.alerts.items.isEmpty)
    }

    @Test func selectionChangesAreIgnoredWhileThePanelIsClosed() {
        controller.selectionChanged([remote("a.jpg")])
        #expect(downloader.calls.isEmpty)
    }

    @Test func closingWhileLoadingCancelsQuietly() async throws {
        let gate = Gate()
        downloader.hold("/sdcard/Download/a.mp4", gate)
        controller.toggle([remote("a.mp4")])
        try await waitUntil { downloader.calls.count == 1 }
        controller.toggle([remote("a.mp4")]) // Space again
        #expect(controller.loadingName == nil && !controller.isActive)
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(presenter.shown.isEmpty)
        #expect(alerts.items.isEmpty)
    }

    @Test func failureShowsAnAlertAndStopsTheSpinner() async throws {
        downloader.fail("/sdcard/Download/secret.txt", .permissionDenied("/sdcard/Download/secret.txt"))
        controller.toggle([remote("secret.txt")])
        try await waitUntil { alerts.items.count == 1 }
        #expect(alerts.items[0].message.contains("secret.txt"))
        #expect(controller.loadingName == nil && !controller.isActive)
        #expect(presenter.shown.isEmpty)
    }

    @Test func deviceGoneMidDownloadStopsTheSpinnerWithAnAlert() async throws {
        let gate = Gate()
        downloader.hold("/sdcard/Download/a.mp4", gate)
        downloader.fail("/sdcard/Download/a.mp4", .connectionClosed)
        controller.toggle([remote("a.mp4")])
        try await waitUntil { downloader.calls.count == 1 }
        await gate.open()
        try await waitUntil { alerts.items.count == 1 }
        #expect(controller.loadingName == nil)
    }

    @Test func browserTeardownCancelsWithoutAnAlert() async throws {
        let gate = Gate()
        downloader.hold("/sdcard/Download/a.mp4", gate)
        controller.toggle([remote("a.mp4")])
        try await waitUntil { downloader.calls.count == 1 }
        controller.cancel()
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(alerts.items.isEmpty && presenter.shown.isEmpty && controller.loadingName == nil)
    }

    @Test func panelClosedByTheUserStopsFollowing() async throws {
        controller.toggle([remote("a.jpg")])
        try await waitUntil { presenter.shown.count == 1 }
        presenter.isVisible = false
        controller.panelDidClose()
        controller.selectionChanged([remote("b.jpg")])
        #expect(downloader.calls == ["/sdcard/Download/a.jpg"])
    }
}
