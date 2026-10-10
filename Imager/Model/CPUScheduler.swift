import Foundation

/// A counting semaphore that limits how many optimizer processes run at once, so a folder of a
/// thousand images doesn't launch a thousand processes.
actor CPUScheduler {
    private var available: Int
    private var limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        available = self.limit
    }

    /// Changing the limit takes effect as slots are released.
    func setLimit(_ newLimit: Int) {
        let newLimit = max(1, newLimit)
        available += newLimit - limit
        limit = newLimit
        wakeWaiters()
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        available += 1
        wakeWaiters()
    }

    private func wakeWaiters() {
        while available > 0, !waiters.isEmpty {
            available -= 1
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` once a slot is free.
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
