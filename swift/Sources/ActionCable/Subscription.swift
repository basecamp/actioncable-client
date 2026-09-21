import Foundation

/// One channel subscription on a client. Read what the channel sends from
/// ``messages``, and talk back with ``perform(_:data:)`` or ``send(_:)``.
///
/// A lock rather than an actor: the client hands a subscription a confirmation
/// or a message from inside its own isolation and must not be made to wait, and
/// ``key``, ``messages`` and ``error`` read better without an `await` in front
/// of them. It is the same `sendMu` the Go client holds.
public final class Subscription: @unchecked Sendable {
    /// The JSON identifier the server knows this subscription by, and the one
    /// it echoes back on everything it sends here.
    public let key: String

    /// Everything the channel broadcasts or transmits to this subscription. It
    /// ends when the subscription is unsubscribed, rejected, or the client
    /// stops, once the last callback has returned — ``error`` says which it
    /// was.
    ///
    /// Read it promptly. Messages that arrive with the buffer full are dropped
    /// and logged rather than stalling the connection; `messageBuffer` sizes
    /// the buffer for a slow consumer.
    public let messages: AsyncStream<Message>

    let confirmed = Signal()
    let rejected = Signal()

    private let callbacks: Dispatcher
    private let onConnected: (@Sendable (Bool) async -> Void)?
    private let onDisconnected: (@Sendable (Bool) async -> Void)?
    private let onRejected: (@Sendable () async -> Void)?

    private let mutex = NSLock()
    private let deliveries: AsyncStream<Message>.Continuation
    private var client: ActionCableClient?
    private var closed = false
    private var reason: (any Error)?

    init(
        client: ActionCableClient,
        key: String,
        buffer: Int,
        onConnected: (@Sendable (Bool) async -> Void)?,
        onDisconnected: (@Sendable (Bool) async -> Void)?,
        onRejected: (@Sendable () async -> Void)?
    ) {
        var continuation: AsyncStream<Message>.Continuation!
        messages = AsyncStream(bufferingPolicy: .bufferingOldest(buffer)) { continuation = $0 }
        let deliveries = continuation!
        self.deliveries = deliveries

        self.client = client
        self.key = key
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.onRejected = onRejected
        callbacks = Dispatcher(afterStop: { deliveries.finish() })
    }

    /// Why the subscription ended: ``ActionCableError/unsubscribed``,
    /// ``ActionCableError/rejected(identifier:)``, or whatever stopped the
    /// client. It is nil while the subscription is live.
    public var error: (any Error)? {
        mutex.lock()
        defer { mutex.unlock() }

        return reason
    }

    /// Invokes an action on the channel — the equivalent of the JavaScript
    /// client's `perform`. `data` must encode to a JSON object.
    public func perform(_ action: String, data: some Encodable) async throws {
        let fields = try object(from: data, for: action)

        try await send(command: Command(name: .message, identifier: key, data: try payload(action, fields)))
    }

    /// Invokes an action on the channel with nothing alongside it.
    public func perform(_ action: String) async throws {
        try await send(command: Command(name: .message, identifier: key, data: try payload(action, [:])))
    }

    /// Delivers data to the channel as-is, without naming an action. Rails
    /// routes it to the channel's `receive` method.
    public func send(_ data: some Encodable) async throws {
        try await send(command: Command(name: .message, identifier: key, data: try encoded(data)))
    }

    /// Tells the server to drop the subscription and ends ``messages``. The
    /// command goes out on the client's own task, so it works from one that has
    /// already been cancelled — which, at teardown, is usually the one at hand.
    public func unsubscribe() async throws {
        if let client = currentClient() {
            try await client.unsubscribe(self)
        }
    }

    private func send(command: Command) async throws {
        if let client = currentClient() {
            try await client.send(command)
        } else {
            throw ActionCableError.notConnected
        }
    }

    private func payload(_ action: String, _ fields: [String: JSONValue]) throws -> String {
        var fields = fields
        fields["action"] = .string(action)

        return try encoded(fields)
    }

    private func object(from data: some Encodable, for action: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(try encoded(data).utf8))

        if case .object(let fields) = value {
            return fields
        } else {
            throw ActionCableError.dataIsNotAnObject(action: action)
        }
    }

    private func encoded(_ data: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            return String(decoding: try encoder.encode(data), as: UTF8.self)
        } catch {
            throw ActionCableError.unencodableData(underlying: error)
        }
    }

    /// Passes the server's verdict on. A holder that unsubscribed between the
    /// registration's holders being listed and this call has nothing to hear.
    func confirm(reconnected: Bool) {
        if !isClosed {
            // The callback is queued before the verdict is published: a
            // subscribe woken by the verdict may unsubscribe at once, and that
            // must not get ahead of the callback for the event that woke it.
            if let onConnected {
                callbacks.dispatch { await onConnected(reconnected) }
            }
            confirmed.signal()
        }
    }

    func reject() {
        if let onRejected {
            callbacks.dispatch(onRejected)
        }
        rejected.signal()
        close(reason: rejection)
    }

    var rejection: any Error {
        ActionCableError.rejected(identifier: key)
    }

    func disconnect(willReconnect: Bool) {
        if let onDisconnected {
            callbacks.dispatch { await onDisconnected(willReconnect) }
        }
    }

    func deliver(_ message: Message) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        // A closed subscription has nothing left to receive, and nothing to
        // report.
        if closed {
            return true
        }

        switch deliveries.yield(message) {
        case .enqueued, .terminated:
            return true
        case .dropped:
            return false
        @unknown default:
            return false
        }
    }

    /// Ends the subscription for the reason given. Deliveries stop at once;
    /// ``messages`` itself ends from the callback task, after the callbacks
    /// already queued have run, so a reader that sees it end knows no callback
    /// is behind it.
    func close(reason: any Error) {
        mutex.lock()
        if !closed {
            closed = true
            self.reason = reason
            // The client holds its subscriptions and each of them holds the
            // client; letting go here is what breaks the cycle.
            client = nil
        }
        mutex.unlock()

        callbacks.stop()
    }

    private var isClosed: Bool {
        mutex.lock()
        defer { mutex.unlock() }

        return closed
    }

    private func currentClient() -> ActionCableClient? {
        mutex.lock()
        defer { mutex.unlock() }

        return client
    }
}
