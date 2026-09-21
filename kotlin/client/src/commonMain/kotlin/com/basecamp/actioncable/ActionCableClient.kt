package com.basecamp.actioncable

import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.concurrent.Volatile
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Owns one connection to an Action Cable server and the subscriptions running
 * over it. Build one, start it with [connect], and hang up with [close]. It is
 * safe to use from several coroutines at once.
 *
 * Every knob Go's package sets with a functional option is a named argument
 * here, and the defaults are the same.
 *
 * @param url the Action Cable endpoint, typically `wss://host/cable`. Nothing
 *   touches the network until [connect].
 * @param transport the network handler. Defaults to the platform's own.
 * @param protocols the protocols offered during the handshake, most preferred
 *   first. The server picks one and the client speaks it for the rest of the
 *   connection.
 * @param additionalProtocols protocols offered ahead of [protocols], so
 *   preferring a new protocol doesn't mean restating the ones to fall back to.
 * @param headers the headers sent on the upgrade request. An Action Cable
 *   server authorizes that request, so this is where a session cookie or a
 *   bearer token goes.
 * @param buildHeaders headers asked for on every dial rather than set once. A
 *   client reconnects on its own for as long as it runs, which is longer than a
 *   credential that expires lives, and a reconnect carrying the token the first
 *   dial used would be turned down for good. What this returns is laid over
 *   [headers], so an Origin or a token given there survives. Throwing turns
 *   down that dial, and the client tries again on its backoff.
 * @param cookie shorthand for sending one Cookie header.
 * @param origin the Origin header. Rails checks it unless the server disables
 *   request forgery protection. Assumed from [url] when not given.
 * @param logger where the client's chatter goes. Nowhere by default.
 * @param stopOnError a predicate for connection errors that retrying cannot
 *   repair. It sees header, dial, and established-connection failures. When it
 *   returns true the client stops with that error instead of reconnecting. It
 *   runs in the connection loop and must return promptly.
 * @param staleAfter how long a connection may go without a frame before it
 *   counts as dead. The server beats every three seconds; the default is six,
 *   so two missed beats.
 * @param initialBackoff the first reconnect delay. It doubles per failed
 *   attempt up to [longestBackoff], and is spread with jitter.
 * @param maxAttempts how many connection attempts may fail in a row before the
 *   client stops with a [GaveUpException]. A welcome resets the count, so it
 *   bounds an outage rather than the client's lifetime. Zero, the default,
 *   keeps trying until [close].
 * @param subscribeRetry how often an unconfirmed subscribe command is resent.
 *   Half a second, like the JavaScript client's guarantor.
 * @param messageBuffer how many messages a subscription buffers before it
 *   starts dropping them.
 */
class ActionCableClient(
    val url: String,
    private val transport: Transport = defaultTransport(),
    protocols: List<Protocol> = listOf(V1Json),
    additionalProtocols: List<Protocol> = emptyList(),
    headers: Headers = Headers.EMPTY,
    private val buildHeaders: (suspend () -> Headers)? = null,
    cookie: String? = null,
    origin: String? = null,
    private val logger: Logger = Logger.NONE,
    private val stopOnError: ((Throwable) -> Boolean)? = null,
    private val staleAfter: Duration = 6.seconds,
    private val initialBackoff: Duration = 1.seconds,
    private val longestBackoff: Duration = 30.seconds,
    private val maxAttempts: Int = 0,
    private val subscribeRetry: Duration = 500.milliseconds,
    private val messageBuffer: Int = 64,
) {
    private val protocols = additionalProtocols + protocols
    private val headers = assumedOrigin(headers.withOptional("Cookie", cookie).withOptional("Origin", origin))

    /**
     * Everything the client runs is launched here rather than in the caller's
     * scope: a connection outlives the coroutine that opened it and lives until
     * [close]. The callback dispatchers outlive even that, since a subscription
     * ends its message flow only once its last callback has returned.
     */
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    /** Guards every field below it, and the registrations. */
    private val mutex = Mutex()
    private val subscriptions = mutableMapOf<String, Registration>()

    @Volatile
    private var conn: Conn? = null

    /** The protocol the server picked for the connection in hand. */
    @Volatile
    private var protocol: Protocol? = null

    @Volatile
    private var attempts = 0

    /** Why the latest attempt failed, kept so a connect that gives up waiting can say what it was waiting on. */
    @Volatile
    private var lastError: Throwable? = null

    @Volatile
    private var reconnected = false

    @Volatile
    private var welcomed = false

    @Volatile
    private var everWelcomed = false

    @Volatile
    private var stopped = false

    @Volatile
    private var failure: Throwable? = null

    @Volatile
    private var runJob: Job? = null

    /**
     * Serializes writes to the connection. It is its own lock so a slow write
     * doesn't hold up everything else reading the client's state.
     */
    private val writeMutex = Mutex()

    private val firstWelcome: CompletableJob = Job()
    private val stopping: CompletableJob = Job()

    /**
     * Completes when the client has stopped for good — closed, told by the
     * server not to come back, out of attempts, or unable to connect in the
     * first place — and will neither reconnect nor deliver anything more.
     * [error] says why. Join it to wait.
     */
    val done: Job get() = stopping

    /** Whether a connection is up and welcomed. */
    val isConnected: Boolean get() = welcomed && conn != null

    /**
     * Why the client stopped, and null while it is still running or has yet to
     * be started. It is a [ClosedException], a [GaveUpException], an
     * [UnsupportedSubprotocolException], a [NoProtocolsException], a
     * [DisconnectException], an error [stopOnError] recognized, or a
     * [ConnectCancelledException] from a connect that was cut short.
     */
    val error: Throwable? get() = if (stopped) failureOrClosed() else null

    /**
     * Starts the client and returns once the server has sent its welcome.
     * Failed connection attempts are retried until that happens, this coroutine
     * is cancelled, the server tells us not to come back, or [stopOnError]
     * recognizes a failure as terminal.
     *
     * Cancelling bounds the wait, not a connection that got through: that lives
     * until [close]. Wrap the call in `withTimeout` to give up after a while.
     *
     * A connect that throws leaves the client stopped, with nothing running
     * behind it, so a client that failed to connect is one to throw away. The
     * one exception is [AlreadyConnectedException], which says the client was
     * running fine before the call and still is.
     */
    suspend fun connect() {
        mutex.withLock {
            if (stopped) {
                throw failureOrClosed()
            }
            if (runJob != null) {
                throw AlreadyConnectedException()
            }
            runJob = scope.launch { run() }
        }

        try {
            select<Unit> {
                firstWelcome.onJoin { }
                stopping.onJoin { throw stoppedBecause() }
            }
        } catch (cancellation: CancellationException) {
            throw giveUpWaiting(cancellation)
        }
    }

    /**
     * Subscribes to a channel and returns once the server confirms it. The
     * subscription outlives reconnects — it is resubscribed automatically — so
     * it stays valid until [Subscription.unsubscribe].
     *
     * Subscribing to an identifier the client already holds shares the server's
     * one subscription for it instead of asking for another, which Rails would
     * ignore. Every subscription sharing an identifier gets every message, and
     * the server hears unsubscribe from the last one to go.
     *
     * The callbacks run on their own coroutine, one at a time, in the order the
     * events happened, so [close], [subscribe] and [Subscription.unsubscribe]
     * all work from inside one. The last of them has returned by the time the
     * subscription's message flow ends.
     *
     * @param onConnected called every time the server confirms the
     *   subscription, including after a reconnect — which is what its argument
     *   reports.
     * @param onDisconnected called when the connection drops, with whether the
     *   client intends to dial again.
     * @param onRejected called when the channel rejects the subscription.
     * @throws RejectedException when the channel turns the subscription down.
     */
    suspend fun subscribe(
        identifier: Identifier,
        onConnected: (suspend (reconnected: Boolean) -> Unit)? = null,
        onDisconnected: (suspend (willReconnect: Boolean) -> Unit)? = null,
        onRejected: (suspend () -> Unit)? = null,
    ): Subscription {
        val key = identifier.key

        val subscription: Subscription
        val shared: Boolean
        val confirmedAlready: Boolean
        mutex.withLock {
            if (stopped) {
                throw failureOrClosed()
            }
            if (runJob == null) {
                throw NotConnectedException()
            }
            subscription = Subscription(this, scope, key, messageBuffer, onConnected, onDisconnected, onRejected)
            val registration = subscriptions[key]
            shared = registration != null
            val holding = registration ?: Registration().also { subscriptions[key] = it }
            holding.holders.add(subscription)
            confirmedAlready = holding.confirmed
        }

        if (confirmedAlready) {
            // The server said yes to this identifier on the connection in hand
            // and won't say so again, so the new holder is as confirmed as the rest.
            subscription.confirm(false)
            return subscription
        }

        // A shared identifier's subscribe is already out, or goes out with the
        // next welcome, and its verdict is this subscription's too.
        if (!shared) {
            try {
                send(Command(CommandName.SUBSCRIBE, key))
            } catch (failed: Exception) {
                // Nothing to do about it here: the connection will subscribe
                // again as soon as it is welcomed back.
                logger.log("actioncable: subscribing to $key: $failed")
            }
        }

        return awaitVerdict(subscription)
    }

    /**
     * Hangs up, stops reconnecting, and ends every subscription's message flow.
     * It is safe to call from a subscription callback, and safe to call twice.
     */
    suspend fun close() {
        shutdown(ClosedException())
    }

    private suspend fun awaitVerdict(subscription: Subscription): Subscription {
        try {
            select<Unit> {
                subscription.confirmed.onJoin { }
                subscription.rejected.onJoin {
                    val rejection = subscription.rejection()
                    forget(subscription, rejection)
                    throw rejection
                }
                stopping.onJoin {
                    val failure = stoppedBecause()
                    forget(subscription, failure)
                    throw failure
                }
            }
        } catch (cancellation: CancellationException) {
            withContext(NonCancellable) { abandon(subscription, cancellation) }
            throw cancellation
        }

        return subscription
    }

    /**
     * Forgets a subscription its caller gave up waiting on. When it was the
     * last holder of an identifier the server has heard a subscribe for, the
     * server is told to let go, or it would keep the subscription and ignore
     * the next subscribe for it as a duplicate. The connection may well be gone
     * by now, and then there is nothing to tell.
     *
     * The unsubscribe is sent before returning rather than in the background so
     * a subscribe for the same identifier that follows can't get ahead of it.
     */
    private suspend fun abandon(subscription: Subscription, reason: Throwable) {
        val (last, heard) = forget(subscription, reason)
        if (last && heard) {
            trySend(Command(CommandName.UNSUBSCRIBE, subscription.key))
        }
    }

    /**
     * Stops a client whose connect ran out of time, unless the welcome landed
     * in the same instant, in which case the connection is kept. Both are
     * settled under one lock, so a welcome can't slip in between the check and
     * the stop and be torn down for its trouble.
     *
     * The client records a [ConnectCancelledException] naming what it was
     * waiting out, and the caller still sees the cancellation its own coroutine
     * was given, with that failure as the cause.
     */
    private suspend fun giveUpWaiting(cancellation: CancellationException): Throwable = withContext(NonCancellable) {
        val abandoned =
            mutex.withLock {
                if (everWelcomed) {
                    null
                } else {
                    val reason = ConnectCancelledException(lastError)
                    stopLocked(reason)
                    reason
                }
            }

        if (abandoned == null) {
            cancellation
        } else {
            awaitStopped()
            CancellationException("actioncable: connecting to $url", abandoned)
        }
    }

    private suspend fun shutdown(reason: Throwable) {
        mutex.withLock { stopLocked(reason) }

        awaitStopped()
    }

    /** Hangs up whatever connection a stopped client still has open and waits until nothing is running any more. */
    private suspend fun awaitStopped() {
        val running = runJob
        if (running == null) {
            // Nothing was ever started, so nothing will finish it for us.
            finish()
            return
        }

        conn?.close()
        running.cancelAndJoin()
    }

    private suspend fun run() {
        try {
            while (coroutineContext.isActive) {
                val ended = session()
                if (ended != null && !stopped) {
                    logger.log("actioncable: connection to $url ended: $ended")
                }
                if (stopped) {
                    break
                }

                delay(reconnectDelay())
            }
        } finally {
            withContext(NonCancellable) {
                closeSubscriptions()
                finish()
            }
        }
    }

    /**
     * Runs one connection from dial to hangup and reports why it ended.
     *
     * It answers with the failure rather than throwing it, cancellation
     * included: the run loop above decides what to do next, and the
     * subscriptions have to be told the connection is gone whether it was lost
     * or taken away.
     */
    private suspend fun session(): Throwable? {
        if (protocols.isEmpty()) {
            return stop(NoProtocolsException())
        }

        val headers =
            try {
                dialHeaders()
            } catch (refused: Throwable) {
                return failed(refused)
            }

        val conn =
            try {
                transport.dial(url, DialOptions(subprotocols() + SUBPROTOCOL_UNSUPPORTED, headers))
            } catch (refused: Throwable) {
                return failed(refused)
            }

        try {
            val protocol = negotiated(conn.subprotocol) ?: return stop(unsupported(conn.subprotocol))
            mutex.withLock {
                this.conn = conn
                this.protocol = protocol
            }

            // The guarantor is a child of this scope and never finishes on its
            // own, so what ends the session is always `receive` throwing, and
            // coroutineScope takes the guarantor down with it.
            val ended =
                try {
                    coroutineScope {
                        launch { guaranteeSubscriptions() }
                        receive(conn, protocol)
                    }
                } catch (ended: Throwable) {
                    ended
                }

            return withContext(NonCancellable) {
                // Recording the failure runs ahead of the disconnect so the
                // subscriptions hear that the client is not coming back rather
                // than that it is.
                val failure = failed(ended)
                disconnect()
                failure
            }
        } finally {
            withContext(NonCancellable) { conn.close() }
        }
    }

    /**
     * Records why an attempt ended and, when that was the last one allowed,
     * stops the client.
     */
    private suspend fun failed(ended: Throwable?): Throwable? {
        if (ended == null || stopped || ended is CancellationException) {
            return ended
        }

        if (stopOnError?.invoke(ended) == true) {
            return stop(ended)
        }

        if (countAttempt(ended) == maxAttempts) {
            stop(GaveUpException(lastError))
        }

        return ended
    }

    /**
     * What the opening request carries. Without [buildHeaders] that is what was
     * set once, at construction; with it, what the caller says now, laid over
     * the headers already there.
     */
    private suspend fun dialHeaders(): Headers {
        val build = buildHeaders ?: return headers

        return headers.overlaidWith(build())
    }

    /** Names every protocol the client can speak, most preferred first. */
    private fun subprotocols(): List<String> = protocols.map { it.subprotocol }

    /**
     * Finds the protocol the server picked out of the ones offered. A server
     * that picks the sentinel, names something never offered, or names nothing
     * at all leaves nothing to talk over, and dialing again won't change it.
     */
    private fun negotiated(subprotocol: String): Protocol? = protocols.firstOrNull { it.subprotocol == subprotocol }

    private fun unsupported(subprotocol: String): UnsupportedSubprotocolException = if (subprotocol == SUBPROTOCOL_UNSUPPORTED) {
        UnsupportedSubprotocolException(
            "actioncable: unsupported subprotocol: the server speaks none of ${subprotocols().joinToString(", ")}",
        )
    } else {
        UnsupportedSubprotocolException("actioncable: unsupported subprotocol: \"$subprotocol\"")
    }

    /**
     * Reads until the connection dies. A connection that has gone quiet for
     * longer than [staleAfter] is dead: the server beats a ping every three
     * seconds.
     */
    private suspend fun receive(conn: Conn, protocol: Protocol): Nothing {
        while (true) {
            val payload =
                withTimeoutOrNull(staleAfter) { conn.read() }
                    ?: throw StaleConnectionException("actioncable: no frame in $staleAfter")

            dispatch(protocol, payload)
        }
    }

    private suspend fun dispatch(protocol: Protocol, payload: ByteArray) {
        val incoming =
            try {
                protocol.decode(payload)
            } catch (undecodable: Exception) {
                logger.log("actioncable: dropping undecodable frame: $undecodable")
                return
            }

        when (incoming.kind) {
            Kind.WELCOME -> welcome()

            // The frame itself is the heartbeat, and reading it already reset
            // the staleness deadline.
            Kind.PING -> Unit

            Kind.DISCONNECT -> throw hangUp(incoming)

            Kind.CONFIRMATION -> confirm(incoming.identifier)

            Kind.REJECTION -> reject(incoming.identifier)

            Kind.MESSAGE -> deliver(incoming)
        }
    }

    /**
     * Resets the connection's health and resubscribes everything, the way the
     * server expects after every fresh connection.
     */
    private suspend fun welcome() {
        writeMutex.withLock {
            val identifiers =
                mutex.withLock {
                    attempts = 0
                    welcomed = true
                    reconnected = everWelcomed
                    everWelcomed = true
                    subscriptions.values.forEach {
                        it.pending = true
                        it.confirmed = false
                    }
                    subscriptions.keys.toList()
                }

            firstWelcome.complete()

            resubscribe(identifiers)
        }
    }

    /**
     * Resends subscribe commands until they are confirmed. A subscribe sent
     * while the server was still setting the connection up is simply dropped on
     * the floor, so unconfirmed means unheard.
     */
    private suspend fun guaranteeSubscriptions() {
        while (true) {
            delay(subscribeRetry)

            writeMutex.withLock { resubscribe(pendingIdentifiers()) }
        }
    }

    /**
     * Sends a subscribe for each identifier. The caller holds [writeMutex] from
     * before the identifiers were listed until this returns, so nothing else
     * can get a command out in between. Otherwise an unsubscribe that lands
     * mid-list could write its unsubscribe ahead of the subscribe for the same
     * identifier, and the server would end up holding a subscription nobody
     * here knows about — one it would silently ignore every later subscribe for.
     */
    private suspend fun resubscribe(identifiers: List<String>) {
        identifiers.forEach { identifier ->
            try {
                write(Command(CommandName.SUBSCRIBE, identifier))
            } catch (failed: Exception) {
                logger.log("actioncable: resubscribing to $identifier: $failed")
            }
        }
    }

    private suspend fun confirm(identifier: String) {
        val holders =
            mutex.withLock {
                val registration = subscriptions[identifier]
                // Only an identifier waiting on a verdict has news. The server
                // can confirm twice when a retried subscribe crosses the first
                // confirmation.
                if (registration == null || !registration.pending) {
                    return
                }
                registration.pending = false
                registration.confirmed = true
                registration.holders.toList()
            }

        holders.forEach { it.confirm(reconnected) }
    }

    private suspend fun reject(identifier: String) {
        val holders =
            mutex.withLock {
                subscriptions.remove(identifier)?.holders?.toList() ?: emptyList()
            }

        holders.forEach { it.reject() }
    }

    private suspend fun deliver(incoming: Incoming) {
        val holders = mutex.withLock { holdersOf(incoming.identifier) }

        if (holders.isEmpty()) {
            logger.log("actioncable: no subscription for ${incoming.identifier}, dropping message")
            return
        }

        holders.forEach { subscription ->
            if (!subscription.deliver(incoming.message)) {
                logger.log("actioncable: message buffer full for ${incoming.identifier}, dropping message")
            }
        }
    }

    private suspend fun hangUp(incoming: Incoming): Throwable {
        val disconnect = DisconnectException(incoming.reason, incoming.reconnect)

        return if (incoming.reconnect) {
            disconnect
        } else {
            stop(disconnect)
        }
    }

    /** Tears down the current connection and tells every subscription. */
    private suspend fun disconnect() {
        val holders: List<Subscription>
        val willReconnect: Boolean
        mutex.withLock {
            conn = null
            protocol = null
            welcomed = false
            subscriptions.values.forEach {
                it.pending = false
                it.confirmed = false
            }
            holders = allSubscriptions()
            willReconnect = !stopped
        }

        holders.forEach { it.disconnect(willReconnect) }
    }

    internal suspend fun send(command: Command) {
        writeMutex.withLock { write(command) }
    }

    /** Sends a command the caller has nothing to do about, the way a teardown does. */
    private suspend fun trySend(command: Command) {
        try {
            send(command)
        } catch (failed: Exception) {
            logger.log("actioncable: sending ${command.name} for ${command.identifier}: $failed")
        }
    }

    /** Puts one command on the connection. The caller holds [writeMutex]. */
    private suspend fun write(command: Command) {
        val live = mutex.withLock { if (welcomed) conn?.let { it to protocol!! } else null }

        // Before the welcome the server hasn't finished setting the connection
        // up and throws away whatever it receives, so there is nowhere to send yet.
        val (conn, protocol) = live ?: throw NotConnectedException()

        conn.write(protocol.encode(command))
    }

    /**
     * Drops a subscription and reports whether it was the last one holding that
     * identifier, which is when the server needs to hear about it, and whether
     * the server has heard a subscribe for it on the connection in hand at all.
     */
    internal suspend fun forget(subscription: Subscription, reason: Throwable): Pair<Boolean, Boolean> {
        var last = false
        var heard = false
        mutex.withLock {
            val registration = subscriptions[subscription.key]
            if (registration != null) {
                registration.holders.remove(subscription)
                heard = registration.pending || registration.confirmed
                last = registration.holders.isEmpty()
                if (last) {
                    subscriptions.remove(subscription.key)
                }
            } else {
                last = true
            }
        }

        subscription.close(reason)

        return last to heard
    }

    private suspend fun closeSubscriptions() {
        val holders: List<Subscription>
        val reason: Throwable
        mutex.withLock {
            holders = allSubscriptions()
            subscriptions.clear()
            reason = failureOrClosed()
        }

        holders.forEach { it.close(reason) }
    }

    private fun holdersOf(identifier: String): List<Subscription> = subscriptions[identifier]?.holders?.toList() ?: emptyList()

    private fun allSubscriptions(): List<Subscription> = subscriptions.values.flatMap { it.holders }

    private suspend fun pendingIdentifiers(): List<String> = mutex.withLock {
        subscriptions.filterValues { it.pending }.keys.toList()
    }

    /** Shuts the client down for good: some failures don't get better by dialing again. */
    private suspend fun stop(reason: Throwable): Throwable {
        mutex.withLock { stopLocked(reason) }

        return reason
    }

    /** Marks the client stopped for the reason given, unless an earlier reason already stands. */
    private fun stopLocked(reason: Throwable) {
        stopped = true
        if (failure == null) {
            failure = reason
        }
    }

    private fun finish() {
        stopping.complete()
    }

    private fun stoppedBecause(): Throwable = failureOrClosed()

    private fun failureOrClosed(): Throwable = failure ?: ClosedException()

    /** Records one more failed attempt, and what failed it, and reports how many have failed in a row. */
    private suspend fun countAttempt(ended: Throwable): Int = mutex.withLock {
        attempts++
        lastError = ended
        attempts
    }

    /**
     * Doubles the delay per failed attempt, up to the longest, and spreads the
     * result over the last interval so a restarted server doesn't get every
     * client back at the same instant.
     */
    private fun reconnectDelay(): Duration {
        val doublings = min(max(attempts - 1, 0), 16)
        val delay = minOf(initialBackoff * (1 shl doublings), longestBackoff)

        return delay / 2 + delay / 2 * Random.nextDouble()
    }

    /**
     * Fills in an Origin for the opening request when none was given. Rails
     * compares Origin against the host it serves on and turns down anything
     * else, a request carrying no Origin at all included, so the Action Cable
     * URL's own origin is the one that gets in. A server behind a proxy that
     * terminates TLS sees a different scheme than the URL says, and needs the
     * `origin` argument to say so.
     */
    private fun assumedOrigin(headers: Headers): Headers {
        if (headers["Origin"] != null) {
            return headers
        }

        val origin = originOf(url) ?: return headers

        return headers.with("Origin", origin)
    }
}

private fun Headers.withOptional(name: String, value: String?): Headers = if (value == null) this else with(name, value)

internal fun originOf(rawUrl: String): String? {
    val scheme = rawUrl.substringBefore("://", missingDelimiterValue = "").lowercase()
    val host = rawUrl.substringAfter("://", missingDelimiterValue = "").substringBefore("/").substringBefore("?")
    if (host.isEmpty()) {
        return null
    }

    return when (scheme) {
        "wss", "https" -> "https://$host"
        "ws", "http" -> "http://$host"
        else -> null
    }
}
