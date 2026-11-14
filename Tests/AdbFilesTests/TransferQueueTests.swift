import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

// MARK: - Fakes

/// A clock tests move by hand.
final class ManualClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: Duration.zero)
    var now: @Sendable () -> Duration { { [time] in time.withLock { $0 } } }
    func advance(_ step: Duration) { time.withLock { $0 += step } }
}

/// Scripted engine. Behaviour is chosen by the request's file name.
final class FakeEngine: TransferEngine {
    enum Behavior: Sendable {
        /// Emit these events, then succeed.
        case succeed([TransferEvent])
        /// Wait for the named gate, then succeed.
        case gated(String)
        /// Fail with this error.
        case fail(AdbError)
        /// Run until cancelled (then throw CancellationError, like a closed socket).
        case untilCancelled
        /// Emit `count` byte events of `size`, advancing `clock` by `step` before each.
        case stream(count: Int, size: Int, step: Duration, thenGate: String?)
    }

    private struct State {
        var started: [String] = []
        var destinations: [String] = []
        var running: [String: Int] = [:]
        var peak: [String: Int] = [:]
        var lastEvents: (@Sendable (TransferEvent) -> Void)?
        var behaviors: [String: [Behavior]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let gates: [String: Gate]
    let clock: ManualClock?
    let remoteExisting: Set<String>

    init(gates: [String] = [], clock: ManualClock? = nil, remoteExisting: Set<String> = []) {
        self.gates = Dictionary(uniqueKeysWithValues: gates.map { ($0, Gate()) })
        self.clock = clock
        self.remoteExisting = remoteExisting
    }

    /// Behaviours for successive attempts of `name`; the last one repeats. Default: succeed.
    func script(_ name: String, _ behaviors: Behavior...) { state.withLock { $0.behaviors[name] = behaviors } }

    var started: [String] { state.withLock { $0.started } }
    var destinations: [String] { state.withLock { $0.destinations } }
    func peak(_ serial: String) -> Int { state.withLock { $0.peak[serial, default: 0] } }
    var lastEvents: (@Sendable (TransferEvent) -> Void)? { state.withLock { $0.lastEvents } }

    func run(_ request: TransferRequest, destination: String, events: @escaping @Sendable (TransferEvent) -> Void) async throws
        -> FolderTransferResult {
        let behavior: Behavior = state.withLock { state in
            state.started.append(request.name)
            state.destinations.append(destination)
            state.running[request.serial, default: 0] += 1
            state.peak[request.serial] = max(state.peak[request.serial, default: 0], state.running[request.serial, default: 0])
            state.lastEvents = events
            guard var queue = state.behaviors[request.name], !queue.isEmpty else { return .succeed([]) }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            state.behaviors[request.name] = queue
            return next
        }
        defer { state.withLock { $0.running[request.serial, default: 0] -= 1 } }
        switch behavior {
        case .succeed(let list):
            list.forEach(events)
        case .gated(let name):
            await gates[name]?.wait()
        case .fail(let error):
            throw error
        case .untilCancelled:
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(2)) }
            throw CancellationError()
        case .stream(let count, let size, let step, let gate):
            for _ in 0..<count {
                clock?.advance(step)
                events(.bytes(size))
            }
            if let gate { await gates[gate]?.wait() }
        }
        var result = FolderTransferResult()
        result.copied = 1
        return result
    }

    func remoteExists(serial: String, path: String) async -> Bool { remoteExisting.contains(path) }
}

private func download(_ name: String, serial: String = "A", to folder: String = "/tmp/adbfiles-none") -> TransferRequest {
    TransferRequest(direction: .download, serial: serial, sourcePath: "/sdcard/\(name)", isFolder: false, targetFolder: folder, size: 100)
}

private func upload(_ name: String, serial: String = "A", to folder: String = "/sdcard/Download") -> TransferRequest {
    TransferRequest(direction: .upload, serial: serial, sourcePath: "/Users/me/\(name)", isFolder: false, targetFolder: folder)
}

// MARK: - Tests

@Suite("TransferQueue")
@MainActor
struct TransferQueueTests {
    @Test func runsAtMostTwoPerDeviceInOrderAndDevicesIndependently() async throws {
        let engine = FakeEngine(gates: ["g"])
        for name in ["a", "b", "c", "d"] { engine.script(name, .gated("g")) }
        engine.script("x", .gated("g"))
        let queue = TransferQueue(engine: engine)
        queue.enqueue(["a", "b", "c", "d"].map { download($0) } + [download("x", serial: "B")])
        try await waitUntil { engine.started.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(Set(engine.started) == ["a", "b", "x"], "device A runs 2 in order; device B is independent")
        await engine.gates["g"]?.open()
        try await waitUntil { queue.items.allSatisfy { $0.state.isFinal } }
        // FIFO decides which items get the two slots; within a pair the tasks may begin in either order.
        let onA = engine.started.filter { $0 != "x" }
        #expect(Set(onA.prefix(2)) == ["a", "b"])
        #expect(Set(onA.suffix(2)) == ["c", "d"])
        #expect(engine.peak("A") == 2)
    }

    @Test func progressIsPublishedAtMostTenTimesPerSecond() async throws {
        let clock = ManualClock()
        let engine = FakeEngine(clock: clock)
        // 1,050 callbacks, 1 ms apart → publishes at 100, 200, … 1,000 ms (10) + one final for the last 50.
        engine.script("big", .stream(count: 1050, size: 1000, step: .milliseconds(1), thenGate: nil))
        let queue = TransferQueue(engine: engine, now: clock.now)
        queue.enqueue([download("big")])
        try await waitUntil { queue.items.first?.state.isFinal == true }
        let item = try #require(queue.items.first)
        #expect(item.publishes == 11)
        #expect(item.bytesDone == 1_050_000)
        #expect(item.state == .done(copied: 1, skipped: 0))
    }

    @Test func speedAndETAFromTheManualClock() async throws {
        let clock = ManualClock()
        let engine = FakeEngine(gates: ["hold"], clock: clock)
        // 100 KB every 10 ms for 2 s = 1 MB/s; then hold before finishing.
        engine.script("g", .stream(count: 200, size: 10_000, step: .milliseconds(10), thenGate: "hold"))
        let queue = TransferQueue(engine: engine, now: clock.now)
        queue.enqueue([download("g")])
        try await waitUntil { (queue.items.first?.bytesDone ?? 0) >= 1_900_000 }
        let item = try #require(queue.items.first)
        #expect(abs(item.speed - 1_000_000) < 20_000, "speed \(item.speed)")
        await engine.gates["hold"]?.open()
    }

    @Test func etaUsesRemainingBytes() async throws {
        let clock = ManualClock()
        let engine = FakeEngine(gates: ["hold"], clock: clock)
        // 10 KB every 10 ms (1 MB/s) for 1 s, then hold; the total (3 MB) is reported afterwards.
        engine.script("e", .stream(count: 100, size: 10_000, step: .milliseconds(10), thenGate: "hold"))
        let queue = TransferQueue(engine: engine, now: clock.now)
        queue.enqueue([download("e")])
        try await waitUntil { (queue.items.first?.bytesDone ?? 0) >= 1_000_000 }
        engine.lastEvents?(.prepared(totalBytes: 3_000_000, files: 1))
        try await waitUntil { queue.items.first?.eta != nil }
        let eta = try #require(queue.items.first?.eta)
        // 1 MB/s with 2 MB left → 2 s.
        #expect(eta > .milliseconds(1900) && eta < .milliseconds(2100), "eta \(eta)")
        await engine.gates["hold"]?.open()
    }

    @Test func cancelWhileQueuedNeverStarts() async throws {
        let engine = FakeEngine(gates: ["g"])
        for name in ["a", "b"] { engine.script(name, .gated("g")) }
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a"), download("b"), download("c")])
        try await waitUntil { engine.started.count == 2 }
        let third = try #require(queue.items.last)
        queue.cancel(third.id)
        await engine.gates["g"]?.open()
        try await waitUntil { queue.items.allSatisfy { $0.state.isFinal } }
        #expect(queue.items.last?.state == .cancelled)
        #expect(!engine.started.contains("c"))
    }

    @Test func cancelWhileRunningIsImmediateAndFreesTheSlot() async throws {
        let engine = FakeEngine()
        engine.script("a", .untilCancelled)
        engine.script("b", .untilCancelled)
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a"), download("b"), download("c")])
        try await waitUntil { engine.started.count == 2 }
        queue.cancel(queue.items[0].id)
        #expect(queue.items[0].state == .cancelled)
        try await waitUntil { engine.started.contains("c") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(queue.items[0].state == .cancelled, "the engine's CancellationError must not change it")
        queue.cancel(queue.items[1].id)
    }

    @Test func cancelRacingCompletionStaysCancelled() async throws {
        let engine = FakeEngine(gates: ["g"])
        engine.script("a", .gated("g"))
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a")])
        try await waitUntil { engine.started == ["a"] }
        queue.cancel(queue.items[0].id)
        await engine.gates["g"]?.open() // the engine now returns success
        try await Task.sleep(for: .milliseconds(30))
        #expect(queue.items[0].state == .cancelled)
    }

    @Test func deviceGoneFailsQueuedAndRunningAsRetryable() async throws {
        let engine = FakeEngine()
        engine.script("a", .untilCancelled)
        engine.script("b", .untilCancelled)
        engine.script("other", .untilCancelled)
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a"), download("b"), download("c"), download("other", serial: "B")])
        try await waitUntil { engine.started.count == 3 }
        queue.deviceGone("A")
        try await Task.sleep(for: .milliseconds(30))
        for index in 0..<3 {
            #expect(queue.items[index].state == .failed("The device was disconnected.", retryable: true))
        }
        #expect(queue.items[3].state == .preparing || queue.items[3].state == .running, "device B unaffected")
        queue.cancel(queue.items[3].id)
    }

    @Test func progressAfterDoneIsIgnored() async throws {
        let engine = FakeEngine()
        engine.script("a", .succeed([.bytes(10)]))
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a")])
        try await waitUntil { queue.items[0].state.isFinal }
        let snapshot = queue.items[0]
        engine.lastEvents?(.bytes(999_999))
        engine.lastEvents?(.prepared(totalBytes: 1, files: 1))
        try await Task.sleep(for: .milliseconds(150))
        engine.lastEvents?(.bytes(1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(queue.items[0] == snapshot)
    }

    @Test func retryReusesTheFirstResolvedName() async throws {
        let engine = FakeEngine()
        engine.script("a.txt", .fail(.connectionClosed), .succeed([]))
        let queue = TransferQueue(engine: engine)
        queue.enqueue([upload("a.txt")])
        try await waitUntil { queue.items[0].state.isFinal }
        #expect(queue.items[0].state == .failed(AdbError.connectionClosed.localizedDescription, retryable: true))
        queue.retry(queue.items[0].id)
        try await waitUntil { queue.items[0].state == .done(copied: 1, skipped: 0) }
        #expect(engine.destinations == ["/sdcard/Download/a.txt", "/sdcard/Download/a.txt"])
    }

    @Test func twoSameNamedUploadsAtOnceGetDistinctNames() async throws {
        let engine = FakeEngine(gates: ["g"])
        engine.script("a.txt", .gated("g"))
        let queue = TransferQueue(engine: engine)
        queue.enqueue([upload("a.txt"), upload("a.txt")])
        try await waitUntil { engine.started.count == 2 }
        #expect(Set(engine.destinations) == ["/sdcard/Download/a.txt", "/sdcard/Download/a 2.txt"])
        await engine.gates["g"]?.open()
    }

    @Test func existingRemoteNameIsKeptBoth() async throws {
        let engine = FakeEngine(remoteExisting: ["/sdcard/Download/a.txt", "/sdcard/Download/a 2.txt"])
        let queue = TransferQueue(engine: engine)
        queue.enqueue([upload("a.txt")])
        try await waitUntil { queue.items[0].state.isFinal }
        #expect(engine.destinations == ["/sdcard/Download/a 3.txt"])
    }

    @Test func twoSameNamedDownloadsIntoOneFolderGetDistinctNames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.txt")) // already on the Mac
        let engine = FakeEngine(gates: ["g"])
        engine.script("a.txt", .gated("g"))
        let queue = TransferQueue(engine: engine)
        queue.enqueue([download("a.txt", to: folder.path), download("a.txt", to: folder.path)])
        try await waitUntil { engine.started.count == 2 }
        #expect(Set(engine.destinations.map { ($0 as NSString).lastPathComponent }) == ["a 2.txt", "a 3.txt"])
        await engine.gates["g"]?.open()
    }

    @Test func folderFailuresEndFailedWithCount() async throws {
        final class PartialEngine: TransferEngine {
            func run(_ request: TransferRequest, destination: String, events: @escaping @Sendable (TransferEvent) -> Void) async throws
                -> FolderTransferResult {
                events(.prepared(totalBytes: 10, files: 3))
                var result = FolderTransferResult()
                result.copied = 2
                result.failures = ["x.bin": "denied"]
                return result
            }
            func remoteExists(serial: String, path: String) async -> Bool { false }
        }
        let queue = TransferQueue(engine: PartialEngine())
        queue.enqueue([TransferRequest(direction: .download, serial: "A", sourcePath: "/sdcard/DCIM", isFolder: true, targetFolder: "/tmp/none")])
        try await waitUntil { queue.items[0].state.isFinal }
        #expect(queue.items[0].state == .failed("1 of 3 files failed.", retryable: true))
        #expect(queue.items[0].failures == ["x.bin": "denied"])
    }

    @Test func fixedNameFromFinderIsUsedAsIs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.txt"))
        let engine = FakeEngine()
        let queue = TransferQueue(engine: engine)
        var request = download("a.txt", to: folder.path)
        request.fixedName = "a 2.txt"
        queue.enqueue([request])
        try await waitUntil { queue.items[0].state.isFinal }
        #expect(engine.destinations == [folder.appendingPathComponent("a 2.txt").path])
    }

    @Test func activeSummaryCombinesRunningTransfers() async throws {
        let engine = FakeEngine(gates: ["g"])
        engine.script("a", .gated("g"))
        engine.script("b", .gated("g"))
        let queue = TransferQueue(engine: engine)
        #expect(queue.activeSummary == nil)
        queue.enqueue([download("a"), download("b")])
        try await waitUntil { engine.started.count == 2 }
        engine.lastEvents?(.prepared(totalBytes: 1000, files: 1)) // b: 0 of 1000
        try await waitUntil { queue.items.contains { $0.bytesTotal == 1000 } }
        let summary = try #require(queue.activeSummary)
        #expect(summary.bytesTotal == 1000)
        #expect(summary.fraction == 0)
        await engine.gates["g"]?.open()
        try await waitUntil { queue.activeSummary == nil }
    }

    @Test func uploadCompletionNotifiesTheBrowser() async throws {
        let engine = FakeEngine()
        engine.script("bad.txt", .fail(.connectionClosed))
        let queue = TransferQueue(engine: engine)
        var notified: [String] = []
        queue.onUploadFinished = { serial, folder in notified.append("\(serial):\(folder)") }
        queue.enqueue([upload("ok.txt"), upload("bad.txt"), download("d.txt")])
        try await waitUntil { queue.items.allSatisfy { $0.state.isFinal } }
        #expect(notified == ["A:/sdcard/Download"])
    }
}

@Suite("Conflict naming")
struct ConflictNamingTests {
    @Test(arguments: [
        ("a.txt", ["a.txt"], "a 2.txt"),
        ("a.txt", ["a.txt", "a 2.txt"], "a 3.txt"),
        ("a 2.txt", ["a 2.txt"], "a 3.txt"),
        ("README", ["README"], "README 2"),
        (".nomedia", [".nomedia"], ".nomedia 2"),
        ("Photos", ["Photos", "Photos 2"], "Photos 3"),
        ("archive.tar.gz", ["archive.tar.gz"], "archive.tar 2.gz"),
        ("free.txt", [], "free.txt"),
    ])
    func names(input: String, taken: [String], expected: String) {
        #expect(ConflictNaming.uniqueName(input) { taken.contains($0) } == expected)
    }
}
