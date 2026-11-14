import os

/// Accumulates bytes from the transfer thread and decides, under a lock, when to publish to the UI:
/// at most once per `interval` of the injected clock. Thread-safe and deterministic for tests.
final class ProgressThrottle: Sendable {
    private struct State {
        var pending = 0
        var total = 0
        var publishCount = 0
        var lastPublish: Duration
    }

    private let interval: Duration
    private let now: @Sendable () -> Duration
    private let state: OSAllocatedUnfairLock<State>

    init(interval: Duration = .milliseconds(100), now: @escaping @Sendable () -> Duration) {
        self.interval = interval
        self.now = now
        state = OSAllocatedUnfairLock(initialState: State(lastPublish: now()))
    }

    /// Adds bytes; returns the bytes to publish now with the time of that decision, or nil to wait.
    func add(_ bytes: Int) -> (bytes: Int, at: Duration)? {
        let current = now()
        return state.withLock { state in
            state.pending += bytes
            state.total += bytes
            guard current - state.lastPublish >= interval else { return nil }
            state.lastPublish = current
            state.publishCount += 1
            defer { state.pending = 0 }
            return (state.pending, current)
        }
    }

    /// All bytes added so far, and how many publishes `add` granted.
    var totals: (bytes: Int, publishes: Int) {
        state.withLock { ($0.total, $0.publishCount) }
    }

    /// Returns and clears whatever has not been published yet (for the final update).
    func drain() -> Int {
        state.withLock { state in
            defer { state.pending = 0 }
            return state.pending
        }
    }
}
