/// Lets at most `limit` holders proceed at once; others wait in FIFO order. Cancellation-aware.
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits for a slot. Throws `CancellationError` if the task is cancelled while waiting.
    func acquire() async throws {
        if active < limit, waiters.isEmpty {
            active += 1
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Frees a slot, handing it to the next waiter if any.
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().continuation.resume() // the slot passes over; `active` stays the same
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
