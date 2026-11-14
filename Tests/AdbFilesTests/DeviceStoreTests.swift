import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

// MARK: - Fakes

/// One scripted `trackDevices()` call.
enum TrackSession: Sendable {
    /// Yields the lists, then ends the stream with `end` (nil = stays open until cancelled).
    case lists([[Device]], end: AdbError?)
    /// Stays open; the test finishes it later through `FakeTracker.finishControlled(throwing:)`.
    case controlled
}

final class FakeTracker: DeviceTracking {
    private struct State {
        var sessions: [TrackSession]
        var calls = 0
        var controlled: AsyncThrowingStream<[Device], Error>.Continuation?
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ sessions: [TrackSession]) {
        state = OSAllocatedUnfairLock(initialState: State(sessions: sessions))
    }

    var calls: Int { state.withLock { $0.calls } }

    func finishControlled(throwing error: Error) {
        state.withLock { $0.controlled }?.finish(throwing: error)
    }

    func trackDevices() -> AsyncThrowingStream<[Device], Error> {
        let session: TrackSession? = state.withLock { state in
            state.calls += 1
            return state.sessions.isEmpty ? nil : state.sessions.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch session {
            case .lists(let lists, let end):
                for list in lists { continuation.yield(list) }
                if let end { continuation.finish(throwing: end) }
            case .controlled:
                state.withLock { $0.controlled = continuation }
            case nil:
                break // script exhausted: stay open so the loop parks instead of spinning
            }
        }
    }
}

final class FakeStarter: ServerStarting {
    private let state: OSAllocatedUnfairLock<(results: [AdbError?], calls: Int)>

    /// Each entry is the outcome of one call: nil = success.
    init(_ results: [AdbError?]) {
        state = OSAllocatedUnfairLock(initialState: (results, 0))
    }

    var calls: Int { state.withLock { $0.calls } }

    func startAdbServer() async throws {
        let result: AdbError? = state.withLock { state in
            state.calls += 1
            return state.results.isEmpty ? nil : state.results.removeFirst()
        }
        if let result { throw result }
    }
}

/// Records requested back-off durations and returns immediately.
final class SleepRecorder: Sendable {
    private let durations = OSAllocatedUnfairLock(initialState: [Duration]())
    var recorded: [Duration] { durations.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [durations] duration in
            durations.withLock { $0.append(duration) }
            await Task.yield()
            try Task.checkCancellation()
        }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private let phone = Device(serial: "PHONE1", state: .device, model: "Pixel_4")
private let locked = Device(serial: "LOCKED", state: .unauthorized)

// MARK: - Tests

@Suite("DeviceStore loop")
@MainActor
struct DeviceStoreTests {
    @Test func startsServerOnceThenTracks() async throws {
        let tracker = FakeTracker([.lists([], end: .serverNotRunning), .lists([[phone]], end: nil)])
        let starter = FakeStarter([nil])
        let store = DeviceStore(client: tracker, launcher: starter, sleep: SleepRecorder().sleep)
        store.start()
        try await waitUntil { store.phase == .ready }
        #expect(store.devices == [phone])
        #expect(starter.calls == 1)
        #expect(store.selectedSerial == "PHONE1")
    }

    @Test func startFailureKeepsAdbOutputOnScreen() async throws {
        let tracker = FakeTracker([
            .lists([], end: .serverNotRunning), .lists([], end: .serverNotRunning), .lists([], end: .serverNotRunning),
        ])
        let starter = FakeStarter([.serverStartFailed("cannot bind 5037")])
        let sleeper = SleepRecorder()
        let store = DeviceStore(client: tracker, launcher: starter, sleep: sleeper.sleep)
        store.start()
        try await waitUntil { tracker.calls == 4 } // 3 scripted failures, then parked
        #expect(starter.calls == 1, "server start is attempted once per failure streak")
        #expect(store.phase == .failed(AdbError.serverStartFailed("cannot bind 5037").localizedDescription))
    }

    @Test func adbMissingStopsTheLoop() async throws {
        let tracker = FakeTracker([.lists([], end: .serverNotRunning)])
        let sleeper = SleepRecorder()
        let store = DeviceStore(client: tracker, launcher: FakeStarter([.adbNotFound]), sleep: sleeper.sleep)
        store.start()
        try await waitUntil { store.phase == .adbMissing }
        try await Task.sleep(for: .milliseconds(50))
        #expect(tracker.calls == 1)
        #expect(sleeper.recorded.isEmpty)
    }

    @Test func reconnectsWithBackoffThatResetsOnSuccess() async throws {
        let tracker = FakeTracker([
            .lists([[phone]], end: .connectionClosed),
            .lists([], end: .connectionClosed),
            .lists([], end: .connectionClosed),
            .lists([[phone]], end: .connectionClosed),
        ])
        let sleeper = SleepRecorder()
        let store = DeviceStore(client: tracker, launcher: FakeStarter([]), sleep: sleeper.sleep)
        store.start()
        try await waitUntil { tracker.calls == 5 }
        #expect(sleeper.recorded == [.milliseconds(500), .seconds(1), .seconds(2), .milliseconds(500)])
    }

    @Test func showsErrorOnlyAfterThreeFailures() async throws {
        let tracker = FakeTracker([
            .lists([[phone]], end: .connectionClosed),
            .lists([], end: .connectionClosed),
            .lists([], end: .connectionClosed),
        ])
        let store = DeviceStore(client: tracker, launcher: FakeStarter([]), sleep: SleepRecorder().sleep)
        store.start()
        try await waitUntil { tracker.calls == 4 }
        #expect(store.phase == .failed(AdbError.connectionClosed.localizedDescription))
        #expect(store.devices.isEmpty)
    }

    @Test func staleLoopAfterRetryDoesNotOverwriteState() async throws {
        let tracker = FakeTracker([.controlled, .lists([[phone]], end: nil)])
        let store = DeviceStore(client: tracker, launcher: FakeStarter([]), sleep: SleepRecorder().sleep)
        store.start()
        try await waitUntil { tracker.calls == 1 }
        store.retry()
        try await waitUntil { store.phase == .ready }
        tracker.finishControlled(throwing: AdbError.connectionClosed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.phase == .ready)
        #expect(store.devices == [phone])
        #expect(tracker.calls == 2)
    }

    @Test func selectionPrefersUsableDeviceAndRefusesOthers() async throws {
        let tracker = FakeTracker([.lists([[locked, phone]], end: nil)])
        let store = DeviceStore(client: tracker, launcher: FakeStarter([]), sleep: SleepRecorder().sleep)
        store.start()
        try await waitUntil { store.phase == .ready }
        #expect(store.selectedSerial == "PHONE1")
        #expect(store.select("LOCKED") == false)
        #expect(store.selectedDevice == locked, "unusable devices can still be selected to show their status")
        #expect(store.select("PHONE1") == true)
    }
}
