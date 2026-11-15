import AdbKit
import AppKit
import Foundation
import os
import Testing
@testable import AdbFiles

@MainActor
final class FakeCell: ThumbnailTarget {
    var shownPath: String?
    var images: [NSImage] = []
    func showThumbnail(_ image: NSImage) { images.append(image) }
}

/// Loads that the test completes by hand.
@MainActor
final class ManualLoads {
    var requested: [String] = []
    private let cancelLog = OSAllocatedUnfairLock(initialState: [String]())
    private var waiting: [String: [CheckedContinuation<Data?, Never>]] = [:]

    /// Paths whose awaiting task was cancelled.
    var cancelled: [String] { cancelLog.withLock { $0 } }

    func load(_ file: RemoteFile) async -> Data? {
        requested.append(file.path)
        let log = cancelLog
        let path = file.path
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[file.path, default: []].append($0) }
        } onCancel: {
            log.withLock { $0.append(path) }
        }
    }

    func complete(_ path: String, with data: Data?) {
        for continuation in waiting.removeValue(forKey: path) ?? [] { continuation.resume(returning: data) }
    }

    func isWaiting(_ path: String) -> Bool { waiting[path] != nil }
}

private func photo(_ name: String) -> RemoteFile {
    RemoteFile(name: name, path: "/sdcard/DCIM/\(name)", mode: 0o100660, size: 1_000, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
}

private let png: Data = {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
    return rep?.representation(using: .png, properties: [:]) ?? Data()
}()

@MainActor
@Suite struct ThumbnailBinderTests {
    let loads = ManualLoads()
    let binder: ThumbnailBinder

    init() {
        let loads = self.loads
        binder = ThumbnailBinder { await loads.load($0) }
    }

    private func show(_ cell: FakeCell, _ file: RemoteFile) {
        cell.shownPath = file.path
        binder.bind(cell, to: file)
    }

    @Test func appliesTheResultToTheCellStillShowingThePath() async throws {
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await waitUntil { cell.images.count == 1 }
    }

    @Test func recycledCellDropsTheLateResultAndCancelsTheOldRequest() async throws {
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        show(cell, photo("b.jpg")) // the cell is reused for another row
        try await waitUntil { loads.cancelled == ["/sdcard/DCIM/a.jpg"] }
        loads.complete("/sdcard/DCIM/a.jpg", with: png) // late result for the old row
        try await waitUntil { binder.dropped == 1 }
        #expect(cell.images.isEmpty, "never shows another file's thumbnail")
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/b.jpg") }
        loads.complete("/sdcard/DCIM/b.jpg", with: png)
        try await waitUntil { cell.images.count == 1 }
    }

    @Test func removalCancelsTheRequest() async throws {
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        binder.unbind(cell)
        cell.shownPath = nil
        try await waitUntil { loads.cancelled == ["/sdcard/DCIM/a.jpg"] }
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await Task.sleep(for: .milliseconds(30))
        #expect(cell.images.isEmpty)
    }

    @Test func cellNotShowingThePathAnymoreIgnoresTheResult() async throws {
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        cell.shownPath = "/sdcard/DCIM/other.jpg" // reused without a bind (e.g. an icon-only row)
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await waitUntil { binder.dropped == 1 }
        #expect(cell.images.isEmpty)
    }

    @Test func resultQueuedForABatchIsDroppedWhenTheCellIsReusedBeforeTheBatch() async throws {
        binder.autoFlush = false
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await waitUntil { binder.pendingCount == 1 } // arrived and checked, not yet applied
        // Reused for a folder row (no thumbnail of its own, so nothing would ever replace a wrong image).
        show(cell, RemoteFile(name: "Camera", path: "/sdcard/DCIM/Camera", mode: 0o040770, size: 0, modificationDate: nil))
        binder.flush()
        #expect(cell.images.isEmpty)
    }

    @Test func batchRechecksThePathWhenApplied() async throws {
        binder.autoFlush = false
        let cell = FakeCell()
        show(cell, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await waitUntil { binder.pendingCount == 1 }
        cell.shownPath = "/sdcard/DCIM/b.jpg" // reused without a bind yet
        binder.flush()
        #expect(cell.images.isEmpty)
        #expect(binder.dropped == 1)
    }

    @Test func filesWithoutThumbnailsAreNotRequested() {
        let cell = FakeCell()
        show(cell, RemoteFile(name: "v.mp4", path: "/sdcard/DCIM/v.mp4", mode: 0o100660, size: 300_000_000, modificationDate: nil))
        show(cell, RemoteFile(name: "Camera", path: "/sdcard/DCIM/Camera", mode: 0o040770, size: 0, modificationDate: nil))
        #expect(loads.requested.isEmpty)
    }

    @Test func scrollingBackShowsTheDecodedImageAtOnce() async throws {
        let first = FakeCell()
        show(first, photo("a.jpg"))
        try await waitUntil { loads.isWaiting("/sdcard/DCIM/a.jpg") }
        loads.complete("/sdcard/DCIM/a.jpg", with: png)
        try await waitUntil { first.images.count == 1 }
        binder.unbind(first)
        let second = FakeCell()
        show(second, photo("a.jpg"))
        #expect(second.images.count == 1, "synchronously, from the binder's image cache")
        #expect(loads.requested == ["/sdcard/DCIM/a.jpg"])
    }

    @Test func unbindAllCancelsEverything() async throws {
        let cells = [FakeCell(), FakeCell(), FakeCell()]
        for (index, cell) in cells.enumerated() { show(cell, photo("\(index).jpg")) }
        binder.unbindAll()
        try await waitUntil { Set(loads.cancelled) == ["/sdcard/DCIM/0.jpg", "/sdcard/DCIM/1.jpg", "/sdcard/DCIM/2.jpg"] }
        try await waitUntil { loads.requested.count == 3 }
        for index in 0..<3 { loads.complete("/sdcard/DCIM/\(index).jpg", with: png) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(cells.allSatisfy { $0.images.isEmpty })
    }
}

@Suite struct RowSizeTests {
    @Test func mapping() {
        #expect(RowSize.small.rowHeight == 22 && RowSize.small.iconSize == 16)
        #expect(RowSize.large.rowHeight == 48 && RowSize.large.iconSize == 40)
        #expect(RowSize.small.thumbnailPixels == 160 && RowSize.large.thumbnailPixels == 160)
        #expect(RowSize(rawValue: "large") == .large && RowSize(rawValue: "bogus") == nil)
    }
}
