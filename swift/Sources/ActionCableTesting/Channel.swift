import Foundation

enum Received<Element: Sendable>: Sendable {
    case value(Element)
    case closed
    case cancelled
}

/// A Go channel: a queue of a fixed capacity where a send waits for room and a
/// receive waits for something to take. At capacity zero a send waits for a
/// receiver to be there, which is how the fake connection lets a test know the
/// client actually read the frame it pushed.
final class Channel<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private let mutex = NSLock()
    private var buffer: [Element] = []
    private var receivers: [UUID: CheckedContinuation<Received<Element>, Never>] = [:]
    private var senders: [(ticket: UUID, element: Element, continuation: CheckedContinuation<Bool, Never>)] = []
    private var closed = false

    init(capacity: Int = 0) {
        self.capacity = capacity
    }

    /// Hands an element over, waiting for room. False means the channel closed
    /// first, or the sending task was cancelled.
    @discardableResult
    func send(_ element: Element) async -> Bool {
        let ticket = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                mutex.lock()

                if closed {
                    mutex.unlock()
                    continuation.resume(returning: false)
                } else if let waiting = takeReceiver() {
                    mutex.unlock()
                    waiting.resume(returning: .value(element))
                    continuation.resume(returning: true)
                } else if buffer.count < capacity {
                    buffer.append(element)
                    mutex.unlock()
                    continuation.resume(returning: true)
                } else {
                    senders.append((ticket, element, continuation))
                    mutex.unlock()
                }
            }
        } onCancel: {
            abandonSender(ticket)
        }
    }

    /// Hands an element over only if there is room for it right now.
    @discardableResult
    func trySend(_ element: Element) -> Bool {
        mutex.lock()

        if closed {
            mutex.unlock()
            return false
        } else if let waiting = takeReceiver() {
            mutex.unlock()
            waiting.resume(returning: .value(element))
            return true
        } else if buffer.count < capacity {
            buffer.append(element)
            mutex.unlock()
            return true
        } else {
            mutex.unlock()
            return false
        }
    }

    func receive() async -> Received<Element> {
        let ticket = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                mutex.lock()

                if let element = takeBuffered() {
                    mutex.unlock()
                    continuation.resume(returning: .value(element))
                } else if closed {
                    mutex.unlock()
                    continuation.resume(returning: .closed)
                } else {
                    receivers[ticket] = continuation
                    mutex.unlock()
                }
            }
        } onCancel: {
            abandonReceiver(ticket)
        }
    }

    func close() {
        mutex.lock()
        closed = true
        let waitingReceivers = Array(receivers.values)
        let waitingSenders = senders
        receivers = [:]
        senders = []
        mutex.unlock()

        for receiver in waitingReceivers {
            receiver.resume(returning: .closed)
        }
        for sender in waitingSenders {
            sender.continuation.resume(returning: false)
        }
    }

    /// The caller holds the mutex.
    private func takeBuffered() -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()

            if !senders.isEmpty {
                let sender = senders.removeFirst()
                buffer.append(sender.element)
                sender.continuation.resume(returning: true)
            }

            return element
        }

        if !senders.isEmpty {
            let sender = senders.removeFirst()
            sender.continuation.resume(returning: true)
            return sender.element
        }

        return nil
    }

    /// The caller holds the mutex.
    private func takeReceiver() -> CheckedContinuation<Received<Element>, Never>? {
        if let ticket = receivers.keys.first {
            return receivers.removeValue(forKey: ticket)
        } else {
            return nil
        }
    }

    private func abandonReceiver(_ ticket: UUID) {
        mutex.lock()
        let continuation = receivers.removeValue(forKey: ticket)
        mutex.unlock()

        continuation?.resume(returning: .cancelled)
    }

    private func abandonSender(_ ticket: UUID) {
        mutex.lock()
        let index = senders.firstIndex { $0.ticket == ticket }
        let sender = index.map { senders.remove(at: $0) }
        mutex.unlock()

        sender?.continuation.resume(returning: false)
    }
}

struct Expired: Error {}

/// Runs an operation with a deadline. `ActionCable` keeps one of these to
/// itself; this module can't reach it and needs one of its own.
func within<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws
    -> T
{
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
            throw Expired()
        }

        defer { group.cancelAll() }

        return try await group.next()!
    }
}
