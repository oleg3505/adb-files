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

    /// Combined progress of unfinished transfers, for the status bar and toolbar ring.
    var activeSummary: (fraction: Double, bytesDone: UInt64, bytesTotal: UInt64, speed: Double, eta: Duration?)? {
        let active = items.filter { $0.state.isActive }
        guard !active.isEmpty else { return nil }
        let done = active.reduce(UInt64(0)) { $0 + $1.bytesDone }
        let total = active.reduce(UInt64(0)) { $0 + max($1.bytesTotal, $1.bytesDone) }
        let speed = active.reduce(0.0) { $0 + $1.speed }
        let fraction = total == 0 ? 0 : min(1, Double(done) / Double(total))
        let eta: Duration? = speed > 0 && total > done ? .seconds(Double(total - done) / speed) : nil
        return (fraction, done, total, speed, eta)
    }

    /// Called after an upload finished, so the browser can refresh that folder.
    @ObservationIgnored var onUploadFinished: ((_ serial: String, _ remoteFolder: String) -> Void)?

    @ObservationIgnored private let engine: any TransferEngine
    @ObservationIgnored private let maxPerDevice: Int
    @ObservationIgnored private let now: @Sendable () -> Duration
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Reserved destination names ("local|<folder>|<name>" or "remote|<serial>|<folder>|<name>") → owning item.
    /// A reservation lives until the owner's task has really ended, not just until the item is marked final.
    @ObservationIgnored private var reservations: [String: UUID] = [:]
    /// Items whose engine task is still running (a cancelled one may still be winding down).
    @ObservationIgnored private var liveTasks: Set<UUID> = []
    /// (time, bytesDone) samples per item for the speed window.
    @ObservationIgnored private var samples: [UUID: [(Duration, UInt64)]] = [:]
    /// One-shot callbacks run when an item reaches a final state (file promises wait on these).
    @ObservationIgnored private var completions: [UUID: (TransferItem.State) -> Void] = [:]

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

    @discardableResult
    func enqueue(_ requests: [TransferRequest]) -> [UUID] {
        let new = requests.map { TransferItem(request: $0) }
        items.append(contentsOf: new)
        pump()
        return new.map(\.id)
    }

    /// Enqueues one request and calls `completion` once it ends (done, failed or cancelled).
    func enqueue(_ request: TransferRequest, completion: @escaping (TransferItem.State) -> Void) {
        let item = TransferItem(request: request)
        completions[item.id] = completion
        items.append(item)
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
        // Invalidate the previous attempt now: it may still be winding down and must not report into this one.
        items[index].attempt += 1
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
        // Mark everything first, so cleaning up one item can't start another queued item of this device.
        let affected = items.indices.filter { items[$0].request.serial == serial && items[$0].state.isActive }
        for index in affected {
            items[index].stopReason = .deviceGone
            items[index].state = .failed("The device was disconnected.", retryable: true)
            Logger.transfer.info("transfer failed id=\(self.items[index].id.uuidString.prefix(8), privacy: .public) reason=device-gone")
        }
        for index in affected { finish(index, pumpAfter: false) }
        pump()
    }

    // MARK: - Scheduling

    private func pump() {
        let running = Dictionary(grouping: items.filter { $0.state == .preparing || $0.state == .running }, by: \.request.serial)
            .mapValues(\.count)
        var slots = running
        // A retried item waits until its previous attempt's task has ended (no shared temp file or name).
        for index in items.indices where items[index].state == .queued && !liveTasks.contains(items[index].id) {
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
        liveTasks.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.execute(id: id, attempt: attempt)
            self?.taskEnded(id)
        }
    }

    /// The engine task of `id` has returned: only now its name may be reused and its slot refilled.
    private func taskEnded(_ id: UUID) {
        liveTasks.remove(id)
        releaseReservations(of: id)
        pump()
    }

    private func releaseReservations(of id: UUID) {
        for (key, owner) in reservations where owner == id { reservations[key] = nil }
    }

    private func execute(id: UUID, attempt: Int) async {
        let destination: String
        do {
            guard let resolved = try await resolveDestination(id: id, attempt: attempt) else { return }
            destination = resolved
        } catch {
            // Could not tell whether the name is free (e.g. the stat timed out): never guess, fail retryably.
            guard let index = current(id, attempt) else { return }
            items[index].state = .failed("Couldn’t check the destination: \(error.localizedDescription)", retryable: true)
            finish(index)
            return
        }
        guard let index = current(id, attempt) else { return }
        let request = items[index].request
        let started = now()
        Logger.transfer.info(
            "transfer start id=\(id.uuidString.prefix(8), privacy: .public) dir=\(request.direction.rawValue, privacy: .public) folder=\(request.isFolder) to=\(destination, privacy: .public)"
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

    /// Picks and reserves the keep-both name. Retry reuses the first name when it is still ours: a folder keeps
    /// its partial target (so finished files are skipped); a single file gets a new name if the old one is now
    /// taken by another item or exists. Returns the full destination path.
    private func resolveDestination(id: UUID, attempt: Int) async throws -> String? {
        guard let index = current(id, attempt) else { return nil }
        let request = items[index].request
        if let fixed = request.fixedName {
            // Chosen by the drop destination (Finder already made it unique).
            reservations[reservationKey(request, fixed)] = id
            items[index].resolvedName = fixed
            return items[index].destinationPath
        }
        if request.conflict == .replace, !request.isFolder {
            // The user chose to overwrite: keep the original name unless another item of ours is writing it,
            // in which case fall back to keep-both below (never two transfers into one file).
            let name = items[index].resolvedName ?? request.name
            let owner = reservations[reservationKey(request, name)]
            if owner == nil || owner == id {
                reservations[reservationKey(request, name)] = id
                items[index].resolvedName = name
                return items[index].destinationPath
            }
            Logger.transfer.info("replace fallback keep-both name=\(name, privacy: .public)")
        }
        if let previous = items[index].resolvedName {
            let owner = reservations[reservationKey(request, previous)]
            let heldByOther = owner != nil && owner != id
            var takenOnDisk = false
            if !request.isFolder, !heldByOther {
                switch request.direction {
                case .download:
                    takenOnDisk = FileManager.default.fileExists(atPath: (request.targetFolder as NSString).appendingPathComponent(previous))
                case .upload:
                    takenOnDisk = try await engine.remoteExists(serial: request.serial, path: RemotePath.join(request.targetFolder, previous))
                }
            }
            guard let index = current(id, attempt) else { return nil }
            let stillHeldByOther = reservations[reservationKey(request, previous)].map { $0 != id } ?? false
            if !takenOnDisk, !stillHeldByOther {
                reservations[reservationKey(request, previous)] = id
                return items[index].destinationPath
            }
            items[index].resolvedName = nil // pick a fresh keep-both name below
        }
        var candidate = request.name
        while true {
            let reserved = ConflictNaming.uniqueName(candidate) { reservations[reservationKey(request, $0)] != nil }
            let exists: Bool
            switch request.direction {
            case .download:
                exists = FileManager.default.fileExists(atPath: (request.targetFolder as NSString).appendingPathComponent(reserved))
            case .upload:
                exists = try await engine.remoteExists(serial: request.serial, path: RemotePath.join(request.targetFolder, reserved))
            }
            guard let index = current(id, attempt) else { return nil }
            // No suspension between this check and the insert, so two items can't take the same name.
            if exists || reservations[reservationKey(request, reserved)] != nil {
                candidate = ConflictNaming.uniqueName(reserved) { $0 == reserved }
                continue
            }
            reservations[reservationKey(request, reserved)] = id
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

    /// Ends the item: completion callback, cancel its task. The name reservation is released only when the task
    /// has really ended (`taskEnded`), or now if the item never started.
    private func finish(_ index: Int, pumpAfter: Bool = true) {
        let item = items[index]
        completions.removeValue(forKey: item.id)?(item.state)
        tasks.removeValue(forKey: item.id)?.cancel()
        samples[item.id] = nil
        if !liveTasks.contains(item.id) { releaseReservations(of: item.id) }
        if pumpAfter { pump() }
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
