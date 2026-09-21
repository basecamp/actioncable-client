import Foundation

/// Owns one connection to an Action Cable server and the subscriptions running
/// over it. Make one, start it with ``connect()``, and hang up with
/// ``close()``.
///
/// It keeps the connection alive the way the official JavaScript client does:
/// the server beats a ping every three seconds, and a connection that goes
/// quiet for longer than `staleAfter` is torn down and redialed with backoff.
/// Subscriptions survive reconnects — they are resubscribed as soon as the
/// server says welcome.
///
/// ```swift
/// let client = ActionCableClient(url: "wss://example.com/cable")
/// try await client.connect()
///
/// let room = try await client.subscribe(to: Identifier(channel: "RoomChannel", params: ["id": 42]))
/// Task {
///     for await message in room.messages {
///         print(try message.decode(Said.self).body)
///     }
/// }
///
/// try await room.perform("speak", data: ["body": "Hello!"])
/// ```
///
/// Two things are pluggable. A ``Transport`` carries bytes — the built-in
/// ``URLSessionTransport`` speaks RFC 6455 through `URLSessionWebSocketTask`,
/// and any WebSocket package can be dropped in behind the same protocol. A
/// ``CableProtocol`` speaks one Action Cable wire format, negotiated as one
/// WebSocket subprotocol — ``V1JSON`` implements `actioncable-v1-json`, and a
/// new format is a new protocol rather than a fork of this client.
public actor ActionCableClient {
    private let url: String
    private let transport: any Transport
    private let protocols: [any CableProtocol]
    private let headers: [String: String]
    private let headerProvider: (@Sendable () async throws -> [String: String])?
    private let stopOnError: (@Sendable (any Error) -> Bool)?
    private let logger: (any CableLogger)?
    private let staleAfter: TimeInterval
    private let subscribeRetry: TimeInterval
    private let initialBackoff: TimeInterval
    private let longestBackoff: TimeInterval
    private let maxAttempts: Int
    private let messageBuffer: Int

    private var connection: (any Connection)?
    private var wire: (any CableProtocol)?
    private var registrations: [String: Registration] = [:]
    private var attempts = 0
    /// Why the latest attempt failed, kept so a `connect` that gives up waiting
    /// can say what it was waiting on.
    private var lastAttempt: (any Error)?
    private var reconnected = false
    private var welcomed = false
    private var everWelcomed = false
    private var stopped = false
    private var failure: (any Error)?
    private var runner: Task<Void, Never>?

    /// Serializes writes. Actor isolation can't: it ends at every `await`, and
    /// a resubscribe holds the wire from listing the identifiers until the last
    /// of them is out.
    private let writes = AsyncLock()
    private let welcomeArrived = Signal()
    private let stoppedForGood = Signal()

    /// Builds a client for an Action Cable endpoint, typically
    /// `wss://host/cable`. It does not touch the network until ``connect()``.
    public init(url: String, configuration: Configuration = Configuration()) {
        self.url = url
        transport = configuration.transport
        protocols = configuration.protocols
        headers = configuration.assumingOrigin(of: url)
        headerProvider = configuration.headerProvider
        stopOnError = configuration.stopOnError
        logger = configuration.logger
        staleAfter = configuration.staleAfter
        subscribeRetry = configuration.subscribeRetry
        initialBackoff = configuration.initialBackoff
        longestBackoff = configuration.longestBackoff
        maxAttempts = configuration.maxAttempts
        messageBuffer = configuration.messageBuffer
    }

    /// Starts the client and returns once the server has sent its welcome.
    /// Failed connection attempts are retried until that happens, the calling
    /// task is cancelled, the server tells us not to come back, or
    /// `stopOnError` recognizes one as terminal.
    ///
    /// Cancellation bounds the wait, not a connection that got through: that
    /// lives until ``close()``. A `connect` that throws leaves the client
    /// stopped, with nothing running behind it, so a client that failed to
    /// connect is one to throw away. The one exception is
    /// ``ActionCableError/alreadyConnected``, which says the client was running
    /// fine before the call and still is.
    public func connect() async throws {
        if stopped {
            throw currentFailure()
        }
        if runner != nil {
            throw ActionCableError.alreadyConnected
        }

        runner = Task { await self.run() }

        switch await waitForWelcome() {
        case .connected:
            return
        case .stopped:
            throw currentFailure()
        case .cancelled:
            try await giveUpWaiting()
        }
    }

    /// Whether a connection is up and welcomed.
    public var isConnected: Bool {
        welcomed && connection != nil
    }

    /// Returns when the client has stopped for good — closed, told by the
    /// server not to come back, out of attempts, or unable to connect in the
    /// first place — and will neither reconnect nor deliver anything more.
    /// ``error`` says why.
    public func waitUntilDone() async {
        await stoppedForGood.wait()
    }

    /// Why the client stopped, and nil while it is still running or has yet to
    /// be started. It is one of ``ActionCableError/closed``,
    /// ``ActionCableError/gaveUp(lastAttempt:)``,
    /// ``ActionCableError/unsupportedSubprotocol(chosen:offered:)``,
    /// ``ActionCableError/noProtocols``,
    /// ``ActionCableError/connectCancelled(lastAttempt:)``, a
    /// ``DisconnectError``, or an error `stopOnError` recognized.
    public var error: (any Error)? {
        if stopped {
            return currentFailure()
        } else {
            return nil
        }
    }

    /// Subscribes to a channel and returns once the server confirms it. The
    /// subscription outlives reconnects — it is resubscribed automatically — so
    /// it stays valid until ``Subscription/unsubscribe()``.
    ///
    /// Subscribing to an identifier the client already holds shares the
    /// server's one subscription for it instead of asking for another, which
    /// Rails would ignore. Every subscription sharing an identifier gets every
    /// message, and the server hears unsubscribe from the last one to go.
    ///
    /// The callbacks run on a task of their own, one at a time, in the order
    /// the events happened, so ``close()``, `subscribe` and `unsubscribe` all
    /// work from inside one. The last of them has returned by the time
    /// ``Subscription/messages`` ends.
    ///
    /// - Parameters:
    ///   - onConnected: Called every time the server confirms the
    ///     subscription, with whether this is a reconnect rather than the first
    ///     time.
    ///   - onDisconnected: Called when the connection drops, with whether the
    ///     client intends to dial again.
    ///   - onRejected: Called when the channel rejects the subscription.
    public func subscribe(
        to identifier: Identifier,
        onConnected: (@Sendable (Bool) async -> Void)? = nil,
        onDisconnected: (@Sendable (Bool) async -> Void)? = nil,
        onRejected: (@Sendable () async -> Void)? = nil
    ) async throws -> Subscription {
        let key = try identifier.key()

        if stopped {
            throw currentFailure()
        }
        if runner == nil {
            throw ActionCableError.notConnected
        }

        let subscription = Subscription(
            client: self,
            key: key,
            buffer: messageBuffer,
            onConnected: onConnected,
            onDisconnected: onDisconnected,
            onRejected: onRejected
        )
        let shared = registrations[key] != nil
        let registration = registrations[key] ?? Registration()
        registration.holders.append(subscription)
        registrations[key] = registration

        if registration.confirmed {
            // The server said yes to this identifier on the connection in hand
            // and won't say so again, so the new holder is as confirmed as the
            // rest.
            subscription.confirm(reconnected: false)
            return subscription
        }

        // A shared identifier's subscribe is already out, or goes out with the
        // next welcome, and its verdict is this subscription's too.
        if !shared {
            do {
                try await send(Command(name: .subscribe, identifier: key))
            } catch {
                // Nothing to do about it here: the connection will subscribe
                // again as soon as it is welcomed back.
                log("subscribing to \(key): \(error)")
            }
        }

        return try await settle(subscription)
    }

    /// Hangs up, stops reconnecting, and ends every subscription's message
    /// stream. It is safe to call from a subscription callback, and safe to
    /// call twice.
    public func close() async {
        stopNow(ActionCableError.closed)
        await awaitStopped()
    }

    // MARK: - Connecting

    private enum Welcome {
        case connected
        case stopped
        case cancelled
    }

    private func waitForWelcome() async -> Welcome {
        let welcomeArrived = self.welcomeArrived
        let stoppedForGood = self.stoppedForGood

        return await withTaskGroup(of: Welcome.self) { group in
            group.addTask {
                if await welcomeArrived.wait() {
                    return .connected
                } else {
                    return .cancelled
                }
            }
            group.addTask {
                if await stoppedForGood.wait() {
                    return .stopped
                } else {
                    return .cancelled
                }
            }

            defer { group.cancelAll() }

            return await group.next()!
        }
    }

    /// Stops a client whose `connect` was cancelled, unless the welcome landed
    /// in the same instant, in which case the connection is kept.
    private func giveUpWaiting() async throws {
        if everWelcomed {
            return
        }

        stopNow(ActionCableError.connectCancelled(lastAttempt: lastAttempt))
        await awaitStopped()

        throw currentFailure()
    }

    /// Hangs up whatever connection a stopped client still has open and waits
    /// until nothing is running any more.
    private func awaitStopped() async {
        if let runner {
            runner.cancel()
            await connection?.close()
            await runner.value
        } else {
            // Nothing was ever started, so nothing will finish it for us.
            stoppedForGood.signal()
        }
    }

    // MARK: - The connection loop

    private func run() async {
        while true {
            let ended = await session()
            if let ended, !stopped {
                log("connection to \(url) ended: \(ended)")
            }

            if stopped || Task.isCancelled {
                break
            }

            do {
                try await Task.sleep(nanoseconds: nanoseconds(reconnectDelay()))
            } catch {
                break
            }
        }

        closeSubscriptions()
        stoppedForGood.signal()
    }

    /// Runs one connection from dial to hangup, and returns why it ended.
    private func session() async -> (any Error)? {
        if protocols.isEmpty {
            return stop(ActionCableError.noProtocols)
        }

        let dialing: DialOptions
        do {
            dialing = DialOptions(subprotocols: offeredSubprotocols(), headers: try await dialHeaders())
        } catch {
            return failed(error)
        }

        let connection: any Connection
        do {
            connection = try await transport.dial(url: url, options: dialing)
        } catch {
            return failed(error)
        }

        let wire: any CableProtocol
        do {
            wire = try negotiated(connection.subprotocol)
        } catch {
            await connection.close()
            return stop(error)
        }

        self.connection = connection
        self.wire = wire

        let guarantor = Task { await self.guaranteeSubscriptions() }

        // Recording why the attempt ended comes before telling the
        // subscriptions, so they hear that the client is not coming back rather
        // than that it is.
        let outcome = failed(await receive(over: connection, using: wire))

        guarantor.cancel()
        await guarantor.value
        disconnect()
        await connection.close()

        return outcome
    }

    /// Records why an attempt ended and, when that was the last one allowed,
    /// stops the client.
    private func failed(_ error: any Error) -> any Error {
        if stopped || Task.isCancelled {
            return error
        }

        if let stopOnError, stopOnError(error) {
            return stop(error)
        }

        attempts += 1
        lastAttempt = error
        if attempts == maxAttempts {
            stop(ActionCableError.gaveUp(lastAttempt: error))
        }

        return error
    }

    /// What the opening request carries. Without a header provider that is what
    /// was set once, at construction; with one, what it says now, laid over the
    /// headers already there.
    private func dialHeaders() async throws -> [String: String] {
        if let headerProvider {
            return headers.merging(try await headerProvider()) { _, provided in provided }
        } else {
            return headers
        }
    }

    /// Every protocol the client can speak, most preferred first, and the
    /// sentinel last.
    private func offeredSubprotocols() -> [String] {
        protocols.map(\.subprotocol) + [Subprotocol.unsupported]
    }

    /// Finds the protocol the server picked out of the ones offered. A server
    /// that picks the sentinel, names something never offered, or names nothing
    /// at all leaves nothing to talk over, and dialing again won't change it.
    private func negotiated(_ subprotocol: String) throws -> any CableProtocol {
        if let wire = protocols.first(where: { $0.subprotocol == subprotocol }) {
            return wire
        } else {
            throw ActionCableError.unsupportedSubprotocol(chosen: subprotocol, offered: protocols.map(\.subprotocol))
        }
    }

    /// Reads until the connection dies. A connection that has gone quiet for
    /// longer than `staleAfter` is dead: the server beats a ping every three
    /// seconds.
    private func receive(over connection: any Connection, using wire: any CableProtocol) async -> any Error {
        while true {
            let payload: Data
            do {
                payload = try await withTimeout(staleAfter) { try await connection.read() }
            } catch is TimedOut {
                return ActionCableError.connectionWentQuiet(after: staleAfter)
            } catch {
                return error
            }

            if let ended = await dispatch(payload, using: wire) {
                return ended
            }
        }
    }

    private func dispatch(_ payload: Data, using wire: any CableProtocol) async -> (any Error)? {
        let incoming: Incoming
        do {
            incoming = try wire.decode(payload)
        } catch {
            log("dropping undecodable frame: \(error)")
            return nil
        }

        switch incoming.kind {
        case .welcome:
            await welcome()
        case .ping:
            // The frame itself is the heartbeat, and reading it already reset
            // the staleness deadline.
            break
        case .disconnect:
            return hangUp(incoming)
        case .confirmation:
            confirm(incoming.identifier)
        case .rejection:
            reject(incoming.identifier)
        case .message:
            deliver(incoming)
        }

        return nil
    }

    /// Resets the connection's health and resubscribes everything, the way the
    /// server expects after every fresh connection.
    private func welcome() async {
        await writes.acquire()

        attempts = 0
        welcomed = true
        reconnected = everWelcomed
        everWelcomed = true
        for registration in registrations.values {
            registration.pending = true
            registration.confirmed = false
        }

        welcomeArrived.signal()

        await resubscribe(Array(registrations.keys))
        writes.release()
    }

    /// Resends subscribe commands until they are confirmed. A subscribe sent
    /// while the server was still setting the connection up is simply dropped
    /// on the floor, so unconfirmed means unheard.
    private func guaranteeSubscriptions() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(subscribeRetry))
            } catch {
                return
            }

            await writes.acquire()
            await resubscribe(pendingIdentifiers())
            writes.release()
        }
    }

    /// Sends a subscribe for each identifier. The write lock is held from
    /// before the identifiers were listed until this returns, so nothing else
    /// can get a command out in between. Otherwise an unsubscribe that lands
    /// mid-list could write itself ahead of the subscribe for the same
    /// identifier, and the server would end up holding a subscription nobody
    /// here knows about — one it would silently ignore every later subscribe
    /// for.
    private func resubscribe(_ identifiers: [String]) async {
        for identifier in identifiers {
            do {
                try await write(Command(name: .subscribe, identifier: identifier))
            } catch {
                log("resubscribing to \(identifier): \(error)")
            }
        }
    }

    private func confirm(_ identifier: String) {
        // Only an identifier waiting on a verdict has news. The server can
        // confirm twice when a retried subscribe crosses the first
        // confirmation.
        if let registration = registrations[identifier], registration.pending {
            registration.pending = false
            registration.confirmed = true

            for subscription in registration.holders {
                subscription.confirm(reconnected: reconnected)
            }
        }
    }

    private func reject(_ identifier: String) {
        let holders = registrations[identifier]?.holders ?? []
        registrations[identifier] = nil

        for subscription in holders {
            subscription.reject()
        }
    }

    private func deliver(_ incoming: Incoming) {
        // A frame with an identifier and no message at all is still the
        // channel's to make sense of, so it goes through as an empty one.
        let message = incoming.message ?? Message(Data())
        let holders = registrations[incoming.identifier]?.holders ?? []
        if holders.isEmpty {
            log("no subscription for \(incoming.identifier), dropping message")
            return
        }

        for subscription in holders where !subscription.deliver(message) {
            log("message buffer full for \(incoming.identifier), dropping message")
        }
    }

    private func hangUp(_ incoming: Incoming) -> any Error {
        let disconnected = DisconnectError(reason: incoming.reason, reconnect: incoming.reconnect)

        if incoming.reconnect {
            return disconnected
        } else {
            return stop(disconnected)
        }
    }

    /// Tears down the current connection and tells every subscription.
    private func disconnect() {
        connection = nil
        wire = nil
        welcomed = false
        for registration in registrations.values {
            registration.pending = false
            registration.confirmed = false
        }

        let willReconnect = !stopped
        for subscription in allSubscriptions() {
            subscription.disconnect(willReconnect: willReconnect)
        }
    }

    // MARK: - Writing

    func send(_ command: Command) async throws {
        await writes.acquire()
        defer { writes.release() }

        try await write(command)
    }

    /// Sends on a task of the client's own, so a caller whose own task has
    /// already been cancelled still gets the command out. It is what Go gets
    /// from writing on the client's context rather than the caller's.
    private func send(regardlessOfCancellation command: Command) async throws {
        let sending = Task { try await self.send(command) }

        try await sending.value
    }

    /// Puts one command on the connection. The caller holds the write lock.
    private func write(_ command: Command) async throws {
        // Before the welcome the server hasn't finished setting the connection
        // up and throws away whatever it receives, so there is nowhere to send
        // yet.
        if let connection = connection, let wire = wire, welcomed {
            try await connection.write(try wire.encode(command))
        } else {
            throw ActionCableError.notConnected
        }
    }

    // MARK: - Subscriptions

    private enum Verdict {
        case confirmed
        case rejected
        case stopped
        case cancelled
    }

    private func settle(_ subscription: Subscription) async throws -> Subscription {
        switch await waitForVerdict(on: subscription) {
        case .confirmed:
            return subscription
        case .rejected:
            let rejection = subscription.rejection
            forget(subscription, reason: rejection)
            throw rejection
        case .stopped:
            let failure = currentFailure()
            forget(subscription, reason: failure)
            throw failure
        case .cancelled:
            await abandon(subscription)
            throw CancellationError()
        }
    }

    private func waitForVerdict(on subscription: Subscription) async -> Verdict {
        let confirmed = subscription.confirmed
        let rejected = subscription.rejected
        let stoppedForGood = self.stoppedForGood

        return await withTaskGroup(of: Verdict.self) { group in
            group.addTask {
                if await confirmed.wait() {
                    return .confirmed
                } else {
                    return .cancelled
                }
            }
            group.addTask {
                if await rejected.wait() {
                    return .rejected
                } else {
                    return .cancelled
                }
            }
            group.addTask {
                if await stoppedForGood.wait() {
                    return .stopped
                } else {
                    return .cancelled
                }
            }

            defer { group.cancelAll() }

            return await group.next()!
        }
    }

    /// Forgets a subscription its caller gave up waiting on. When it was the
    /// last holder of an identifier the server has heard a subscribe for, the
    /// server is told to let go, or it would keep the subscription and ignore
    /// the next subscribe for it as a duplicate. The connection may well be
    /// gone by now, and then there is nothing to tell.
    ///
    /// It is sent before returning rather than in the background so a subscribe
    /// for the same identifier that follows can't get ahead of it.
    private func abandon(_ subscription: Subscription) async {
        let (last, heard) = forget(subscription, reason: CancellationError())

        if last && heard {
            try? await send(regardlessOfCancellation: Command(name: .unsubscribe, identifier: subscription.key))
        }
    }

    func unsubscribe(_ subscription: Subscription) async throws {
        let (last, _) = forget(subscription, reason: ActionCableError.unsubscribed)

        if last {
            try await send(regardlessOfCancellation: Command(name: .unsubscribe, identifier: subscription.key))
        }
    }

    /// Drops a subscription and reports whether it was the last one holding
    /// that identifier, which is when the server needs to hear about it, and
    /// whether the server has heard a subscribe for it on the connection in
    /// hand at all.
    @discardableResult
    private func forget(_ subscription: Subscription, reason: any Error) -> (last: Bool, heard: Bool) {
        var last = true
        var heard = false

        if let registration = registrations[subscription.key] {
            registration.holders.removeAll { $0 === subscription }
            heard = registration.pending || registration.confirmed
            last = registration.holders.isEmpty

            if last {
                registrations[subscription.key] = nil
            }
        }

        subscription.close(reason: reason)

        return (last, heard)
    }

    private func closeSubscriptions() {
        let subscriptions = allSubscriptions()
        registrations = [:]
        let failure = currentFailure()

        for subscription in subscriptions {
            subscription.close(reason: failure)
        }
    }

    private func allSubscriptions() -> [Subscription] {
        registrations.values.flatMap(\.holders)
    }

    private func pendingIdentifiers() -> [String] {
        registrations.filter { $0.value.pending }.map(\.key)
    }

    // MARK: - Stopping

    /// Shuts the client down for good: some failures don't get better by
    /// dialing again.
    @discardableResult
    private func stop(_ reason: any Error) -> any Error {
        stopNow(reason)
        runner?.cancel()

        return reason
    }

    /// Marks the client stopped for the reason given, unless an earlier reason
    /// already stands.
    private func stopNow(_ reason: any Error) {
        stopped = true
        if failure == nil {
            failure = reason
        }
    }

    private func currentFailure() -> any Error {
        failure ?? ActionCableError.closed
    }

    /// Doubles the delay per failed attempt, up to the longest, and spreads the
    /// result over the last interval so a restarted server doesn't get every
    /// client back at the same instant.
    private func reconnectDelay() -> TimeInterval {
        let doublings = min(max(attempts - 1, 0), 16)
        let delay = min(initialBackoff * pow(2, Double(doublings)), longestBackoff)

        return delay / 2 + Double.random(in: 0...(delay / 2))
    }

    private func log(_ message: String) {
        logger?.log("actioncable: \(message)")
    }
}

/// The server's one subscription for an identifier, and every ``Subscription``
/// here that shares it. Rails keeps one subscription per identifier per
/// connection and says nothing to a second subscribe for it, so the subscribe
/// command, its verdict, and the retries until then belong to the identifier
/// rather than to each holder.
private final class Registration {
    var holders: [Subscription] = []

    /// Set while a subscribe is out on the connection in hand with no verdict
    /// yet, `confirmed` once the server said yes on it. Both clear when the
    /// connection drops: the next one starts over.
    var pending = true
    var confirmed = false
}
