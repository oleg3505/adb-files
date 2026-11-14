import AdbKit
import AppKit
import os

/// A table cell that can show a thumbnail in place of its icon.
@MainActor
protocol ThumbnailTarget: AnyObject {
    /// The path the cell currently shows (set by the table for every row it binds).
    var shownPath: String? { get }
    func showThumbnail(_ image: NSImage)
}

/// Connects recycled table cells to thumbnail requests.
///
/// A cell asks for the thumbnail of the row it shows; when the cell is reused for another row or removed, the
/// request is cancelled. A result is applied only if the cell still shows that path and the request is still
/// the cell's current one, so a recycled row never shows another file's thumbnail. Results are applied in
/// batches, one per run-loop turn.
@MainActor
final class ThumbnailBinder {
    typealias Load = @MainActor (RemoteFile) async -> Data?
    typealias Cancel = @MainActor (RemoteFile) -> Void

    private struct Binding {
        let file: RemoteFile
        let token: Int
        let task: Task<Void, Never>
    }

    private let load: Load
    private let cancelRequest: Cancel
    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var nextToken = 0
    /// Decoded images by cache key, so scrolling back shows them at once.
    private var images: [String: NSImage] = [:]
    private var imageOrder: [String] = []
    private let imageLimit = 400
    private var pending: [(target: ThumbnailTarget, image: NSImage)] = []
    private var flushScheduled = false
    /// Counters for logs and tests.
    private(set) var dropped = 0
    private(set) var cancelled = 0

    init(load: @escaping Load, cancel: @escaping Cancel) {
        self.load = load
        cancelRequest = cancel
    }

    /// The table showed `file` in `target` (the cell was already reset to the system icon).
    func bind(_ target: ThumbnailTarget, to file: RemoteFile) {
        let id = ObjectIdentifier(target)
        if let existing = bindings[id] {
            if existing.file == file { return } // same row re-displayed: keep the request
            unbind(target)
        }
        guard ThumbnailStrategy.choose(for: file) != .none else { return }
        let key = ThumbnailService.key(for: file)
        if let image = images[key] {
            target.showThumbnail(image)
            return
        }
        nextToken += 1
        let token = nextToken
        let task = Task { [weak self, weak target] in
            guard let self else { return }
            let data = await self.load(file)
            guard let target else { return }
            self.deliver(data, key: key, file: file, token: token, to: target)
        }
        bindings[id] = Binding(file: file, token: token, task: task)
    }

    /// The cell left the table (scrolled away, reloaded): its request is no longer needed.
    func unbind(_ target: ThumbnailTarget) {
        guard let binding = bindings.removeValue(forKey: ObjectIdentifier(target)) else { return }
        binding.task.cancel()
        cancelRequest(binding.file)
        cancelled += 1
    }

    /// Drops every request (folder changed, browser closed).
    func unbindAll() {
        for binding in bindings.values {
            binding.task.cancel()
            cancelRequest(binding.file)
        }
        cancelled += bindings.count
        bindings.removeAll()
        pending.removeAll()
    }

    private func deliver(_ data: Data?, key: String, file: RemoteFile, token: Int, to target: ThumbnailTarget) {
        let id = ObjectIdentifier(target)
        guard bindings[id]?.token == token, target.shownPath == file.path else {
            dropped += 1
            Logger.ui.debug("thumb drop stale path=\(file.path, privacy: .public)")
            return
        }
        bindings[id] = nil
        guard let data, let image = NSImage(data: data) else { return }
        remember(key, image)
        pending.append((target, image))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let clock = ContinuousClock()
        let started = clock.now
        let batch = pending
        pending.removeAll()
        for (target, image) in batch { target.showThumbnail(image) }
        let elapsed = clock.now - started
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        Logger.ui.info("apply thumbs n=\(batch.count) mainMs=\(ms, format: .fixed(precision: 2))")
    }

    private func remember(_ key: String, _ image: NSImage) {
        if images[key] == nil { imageOrder.append(key) }
        images[key] = image
        if imageOrder.count > imageLimit { images[imageOrder.removeFirst()] = nil }
    }
}
