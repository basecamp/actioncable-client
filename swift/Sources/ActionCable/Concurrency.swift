import Foundation

/// A mutex a task can wait on.
///
/// The client serializes its writes the way Go's does, and holds the lock
/// across an `await` — from listing the identifiers to resubscribe until the
/// last of them is on the wire. Actor isolation can't do that: every `await`
/// lets another call in. Waiters are woken in the order they arrived, which is
/// what keeps an unsubscribe behind the resubscribe it raced.
///
/// `NSLock` rather than `Mutex` because `Mutex` wants macOS 15 and this package
/// runs on macOS 12.
final class AsyncLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            mutex.lock()

            if held {
                waiting.append(continuation)
                mutex.unlock()
            } else {
                held = true
                mutex.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        mutex.lock()

        if waiting.isEmpty {
            held = false
            mutex.unlock()
        } else {
            let next = waiting.removeFirst()
            mutex.unlock()
            next.resume()
        }
    }
}

/// A one-shot signal any number of tasks can wait on, and Swift's stand-in for
/// a Go channel that is only ever closed.
///
/// `wait` returns true when the signal came and false when the waiting task was
/// cancelled, so a caller racing several of them can tell which happened.
final class Signal: @unchecked Sendable {
    private let mutex = NSLock()
    private var signalled = false
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var hasSignalled: Bool {
        mutex.lock()
        defer { mutex.unlock() }

        return signalled
    }

    func signal() {
        mutex.lock()

        if signalled {
            mutex.unlock()
        } else {
            signalled = true
            let pending = waiting.values
            waiting = [:]
            mutex.unlock()

            for continuation in pending {
                continuation.resume(returning: true)
            }
        }
    }

    @discardableResult
    func wait() async -> Bool {
        let ticket = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                mutex.lock()

                if signalled {
                    mutex.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiting[ticket] = continuation
                    mutex.unlock()
                }
            }
        } onCancel: {
            abandon(ticket)
        }
    }

    private func abandon(_ ticket: UUID) {
        mutex.lock()
        let continuation = waiting.removeValue(forKey: ticket)
        mutex.unlock()

        continuation?.resume(returning: false)
    }
}

/// Raised by ``withTimeout(_:operation:)`` when the operation outlasts its
/// seconds.
struct TimedOut: Error {}

/// Runs an operation with a deadline, and cancels it when the deadline passes.
/// This is what Go gets from a context with a timeout.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds(seconds))
            throw TimedOut()
        }

        defer { group.cancelAll() }

        return try await group.next()!
    }
}

func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64((seconds * 1_000_000_000).rounded())
}
