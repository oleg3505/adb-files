import AdbKit
import Foundation
import Observation
import os

/// All transfers of the app: FIFO per device, at most `maxPerDevice` running per device.
///
/// A transfer's final state comes from a stop reason recorded before its task is cancelled (user → cancelled,
/// device gone → failed + retryable), never from a thrown `CancellationError` alone. Every event carries the
/// attempt number it belongs to and is ignored once the item is final or retried.
@Observable
@MainActor
final class TransferQueue {
    private(set) var items: [TransferItem] = []

    /// Transfers not yet finished (badge count).
    var activeCount: Int { items.filter { $0.state.isActive }.count }

    /// Called after an upload finished, so the browser can refresh that folder.
    @ObservationIgnored var onUploadFinished: ((_ serial: String, _ remoteFolder: String) -> Void)?

    @ObservationIgnored private let engine: any TransferEngine
    @ObservationIgnored private let maxPerDevice: Int
    @ObservationIgnored private let now: @Sendable () -> Duration
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Reserved destination names: "local|<folder>|<name>" or "remote|<serial>|<folder>|<name>".
    @ObservationIgnored private var reservations: Set<String> = []
    /// (time, bytesDone) samples per item for the speed window.
    @ObservationIgnored private var samples: [UUID: [(Duration, UInt64)]] = [:]

    /// - Parameters:
    ///   - now: Monotonic time; injectable so throttle/speed tests use a manual clock.
    init(engine: any TransferEngine, maxPerDevice: Int = 2, now: (@Sendable () -> Duration)? = nil) {
        self.engine = engine
        self.maxPerDevice = maxPerDevice
        if let now {
            self.now = now
        } else {
            let origin = ContinuousClock.now
            self.now = { ContinuousClock.now - origin }
        }
    }

    // MARK: - Public API

    func enqueue(_ requests: [TransferRequest]) {
        for request in requests {
            items.append(TransferItem(request: request))
        }
        pump()
    }

    func cancel(_ id: UUID) {
        guard let index = index(of: id), items[index].state.isActive else { return }
        items[index].stopReason = .user
        items[index].state = .cancelled
        finish(index)
        Logger.transfer.info("transfer cancelled id=\(id.uuidString.prefix(8), privacy: .public)")
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id) else { return }
        switch items[index].state {
        case .failed, .cancelled: break
        default: return
        }
        items[index].state = .queued
        items[index].stopReason = nil
        items[index].bytesDone = 0
        items[index].speed = 0
        items[index].eta = nil
        items[index].failures = [:]
        pump()
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinal }
    }

    /// The device went away: its unfinished transfers fail and can be retried later.
    func deviceGone(_ serial: String) {
        for index in items.indices where items[index].request.serial == serial && items[index].state.isActive {
            items[index].stopReason = .deviceGone
            items[index].state = .failed("The device was disconnected.", retryable: true)
            finish(index)
            Logger.transfer.info("transfer failed id=\(self.items[index].id.uuidString.prefix(8), privacy: .public) reason=device-gone")
        }
    }

    // MARK: - Scheduling

    private func pump() {
        let running = Dictionary(grouping: items.filter { $0.state == .preparing || $0.state == .running }, by: \.request.serial)
            .mapValues(\.count)
        var slots = running
        for index in items.indices where items[index].state == .queued {
            let serial = items[index].request.serial
            guard slots[serial, default: 0] < maxPerDevice else { continue }
            slots[serial, default: 0] += 1
            start(index)
        }
    }

    private func start(_ index: Int) {
        items[index].attempt += 1
        items[index].state = .preparing
        let id = items[index].id
        let attempt = items[index].attempt
        tasks[id] = Task { [weak self] in await self?.execute(id: id, attempt: attempt) }
    }

    private func execute(id: UUID, attempt: Int) async {
        guard let destination = await resolveDestination(id: id, attempt: attempt) else { return }
        guard let index = current(id, attempt) else { return }
        let request = items[index].request
        let started = now()
        Logger.transfer.info(
            "transfer start id=\(id.uuidString.prefix(8), privacy: .public) dir=\(request.direction.rawValue, privacy: .public) folder=\(request.isFolder)"
        )
        let throttle = ProgressThrottle(now: now)
        let events: @Sendable (TransferEvent) -> Void = { [weak self] event in
            switch event {
            case .prepared(let total, let files):
                Task { @MainActor in self?.prepared(id: id, attempt: attempt, total: total, files: files) }
            case .bytes(let count):
                if let publish = throttle.add(count) {
                    Task { @MainActor in self?.publish(id: id, attempt: attempt, bytes: publish.bytes, at: publish.at) }
                }
            }
        }
        do {
            let result = try await engine.run(request, destination: destination, events: events)
            complete(id: id, attempt: attempt, started: started, throttle: throttle, outcome: .success(result))
        } catch {
            complete(id: id, attempt: attempt, started: started, throttle: throttle, outcome: .failure(error))
        }
    }

    /// Picks and reserves the keep-both name (once; Retry reuses it). Returns the full destination path.
    private func resolveDestination(id: UUID, attempt: Int) async -> String? {
        guard let index = current(id, attempt) else { return nil }
        let request = items[index].request
        if let existing = items[index].resolvedName {
            reservations.insert(reservationKey(request, existing))
            return items[index].destinationPath
        }
        var candidate = request.name
        while true {
            let reserved = ConflictNaming.uniqueName(candidate) { reservations.contains(reservationKey(request, $0)) }
            let exists: Bool
            switch request.direction {
            case .download:
                exists = FileManager.default.fileExists(atPath: (request.targetFolder as NSString).appendingPathComponent(reserved))
            case .upload:
                exists = await engine.remoteExists(serial: request.serial, path: RemotePath.join(request.targetFolder, reserved))
            }
            guard let index = current(id, attempt) else { return nil }
            // No suspension between this check and the insert, so two items can't take the same name.
            if exists || reservations.contains(reservationKey(request, reserved)) {
                candidate = ConflictNaming.uniqueName(reserved) { $0 == reserved }
                continue
            }
            reservations.insert(reservationKey(request, reserved))
            items[index].resolvedName = reserved
            return items[index].destinationPath
        }
    }

    private func reservationKey(_ request: TransferRequest, _ name: String) -> String {
        switch request.direction {
        case .download: "local|\(request.targetFolder)|\(name)"
        case .upload: "remote|\(request.serial)|\(RemotePath.normalized(request.targetFolder))|\(name)"
        }
    }

    // MARK: - Events (main actor, attempt-checked)

    private func prepared(id: UUID, attempt: Int, total: UInt64, files: Int) {
        guard let index = current(id, attempt) else { return }
        items[index].bytesTotal = total
        items[index].fileCount = files
        items[index].state = .running
        if samples[id] == nil { samples[id] = [(now(), items[index].bytesDone)] }
        updateETA(index)
    }

    private func publish(id: UUID, attempt: Int, bytes: Int, at time: Duration) {
        guard let index = current(id, attempt) else { return }
        if items[index].state == .preparing { items[index].state = .running }
        items[index].bytesDone += UInt64(bytes)
        items[index].publishes += 1
        updateSpeed(index, at: time)
    }

    /// Speed over a 3 s window of (time, bytes) samples; `time` is when the throttle decided to publish.
    private func updateSpeed(_ index: Int, at time: Duration) {
        let id = items[index].id
        var window = samples[id, default: []]
        window.append((time, items[index].bytesDone))
        window.removeAll { time - $0.0 > .seconds(3) }
        samples[id] = window
        guard let first = window.first, time > first.0 else { return }
        let elapsed = Double((time - first.0).components.seconds) + Double((time - first.0).components.attoseconds) / 1e18
        items[index].speed = Double(items[index].bytesDone - first.1) / elapsed
        updateETA(index)
    }

    private func updateETA(_ index: Int) {
        let item = items[index]
        guard item.speed > 0, item.bytesTotal > item.bytesDone else { return }
        items[index].eta = .seconds(Double(item.bytesTotal - item.bytesDone) / item.speed)
    }

    private func complete(
        id: UUID, attempt: Int, started: Duration, throttle: ProgressThrottle, outcome: Result<FolderTransferResult, Error>
    ) {
        guard let index = current(id, attempt) else { return }
        let item = items[index]
        // Totals come from the throttle: a publish task still queued behind this call must not lose bytes.
        let unpublished = throttle.drain()
        let totals = throttle.totals
        items[index].bytesDone = UInt64(totals.bytes)
        items[index].publishes = totals.publishes + (unpublished > 0 ? 1 : 0)
        switch outcome {
        case .success(let result) where result.failures.isEmpty:
            items[index].state = .done(copied: result.copied, skipped: result.skipped)
        case .success(let result):
            items[index].failures = result.failures
            items[index].state = .failed("\(result.failures.count) of \(item.fileCount) files failed.", retryable: true)
        case .failure(let error):
            // Reached only when nobody stopped the item (a stop already made it final), so this is a real error.
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            items[index].state = .failed(message, retryable: true)
        }
        let elapsed = now() - started
        let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        let megabytes = Double(items[index].bytesDone) / 1_000_000
        Logger.transfer.info(
            "transfer end id=\(id.uuidString.prefix(8), privacy: .public) state=\(String(describing: self.items[index].state), privacy: .public) bytes=\(self.items[index].bytesDone) ms=\(Int(seconds * 1000)) MBps=\(String(format: "%.1f", megabytes / seconds), privacy: .public) publishes=\(self.items[index].publishes)"
        )
        let request = items[index].request
        let succeeded = if case .done = items[index].state { true } else { false }
        finish(index)
        if request.direction == .upload, succeeded {
            onUploadFinished?(request.serial, request.targetFolder)
        }
    }

    /// Releases the item's slot and name reservation and starts what can run next.
    private func finish(_ index: Int) {
        let item = items[index]
        tasks.removeValue(forKey: item.id)?.cancel()
        samples[item.id] = nil
        if let name = item.resolvedName { reservations.remove(reservationKey(item.request, name)) }
        pump()
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// The item's index if `attempt` is still its current, unfinished attempt.
    private func current(_ id: UUID, _ attempt: Int) -> Int? {
        guard let index = index(of: id), items[index].attempt == attempt, items[index].state.isActive else { return nil }
        return index
    }
}
