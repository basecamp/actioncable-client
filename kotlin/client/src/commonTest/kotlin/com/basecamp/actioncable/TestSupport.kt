package com.basecamp.actioncable

import com.basecamp.actioncable.testing.BRIEFLY
import com.basecamp.actioncable.testing.FakeConn
import com.basecamp.actioncable.testing.FakeTransport
import com.basecamp.actioncable.testing.WAIT
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.fail
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

const val CABLE_URL = "ws://cable.example.com/cable"
const val ROOM_IDENTIFIER = """{"channel":"RoomChannel","id":42}"""

fun room() = Identifier("RoomChannel", mapOf("id" to 42))

/**
 * Runs a test against real time on real threads, the way the Go suite does.
 * The client's own coroutines run on [Dispatchers.Default] and its timers are
 * real, so `runTest`'s virtual clock would only get in the way; what it is here
 * for is the watchdog that fails a wedged test rather than hanging the suite.
 */
fun cableTest(body: suspend CableTest.() -> Unit) = runTest(timeout = 60.seconds) {
    val test = CableTest()
    try {
        withContext(Dispatchers.Default) { test.body() }
    } finally {
        withContext(Dispatchers.Default + NonCancellable) { test.tearDown() }
    }
}

/**
 * One test's clients and background coroutines. Anything started here is on a
 * supervisor, so a connect that is expected to fail doesn't take the test down
 * with it before the test can read the failure.
 */
class CableTest {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    private val clients = mutableListOf<ActionCableClient>()

    /**
     * A client wired to the test log and closed when the test ends. The
     * defaults are the library's, restated so a test can change just the one it
     * is about.
     */
    fun client(
        transport: FakeTransport,
        url: String = CABLE_URL,
        protocols: List<Protocol> = listOf(V1Json),
        additionalProtocols: List<Protocol> = emptyList(),
        headers: Headers = Headers.EMPTY,
        buildHeaders: (suspend () -> Headers)? = null,
        cookie: String? = null,
        origin: String? = null,
        stopOnError: ((Throwable) -> Boolean)? = null,
        staleAfter: Duration = 6.seconds,
        initialBackoff: Duration = 1.seconds,
        longestBackoff: Duration = 30.seconds,
        maxAttempts: Int = 0,
        subscribeRetry: Duration = 500.milliseconds,
        messageBuffer: Int = 64,
    ): ActionCableClient = ActionCableClient(
        url = url,
        transport = transport,
        protocols = protocols,
        additionalProtocols = additionalProtocols,
        headers = headers,
        buildHeaders = buildHeaders,
        cookie = cookie,
        origin = origin,
        logger = { println(it) },
        stopOnError = stopOnError,
        staleAfter = staleAfter,
        initialBackoff = initialBackoff,
        longestBackoff = longestBackoff,
        maxAttempts = maxAttempts,
        subscribeRetry = subscribeRetry,
        messageBuffer = messageBuffer,
    ).also { clients.add(it) }

    /** Connects in the background, since connect waits for a welcome the test still has to send. */
    fun connecting(client: ActionCableClient): Deferred<Unit> = scope.async { client.connect() }

    /** Connects a client and plays the server's welcome, answering with the connection to go on talking over. */
    suspend fun welcomed(client: ActionCableClient, transport: FakeTransport): FakeConn {
        val connecting = connecting(client)
        val conn = transport.accept()
        conn.welcome()
        connecting.await()

        return conn
    }

    /** Subscribes in the background, since subscribe waits for the confirmation the test still has to send. */
    fun subscribing(
        client: ActionCableClient,
        identifier: Identifier = room(),
        onConnected: (suspend (Boolean) -> Unit)? = null,
        onDisconnected: (suspend (Boolean) -> Unit)? = null,
        onRejected: (suspend () -> Unit)? = null,
    ): Deferred<Subscription> = scope.async { client.subscribe(identifier, onConnected, onDisconnected, onRejected) }

    /** Subscribes to the room and confirms it, the setup most tests start from. */
    suspend fun subscribed(client: ActionCableClient, conn: FakeConn): Subscription {
        val subscribing = subscribing(client)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)

        return subscribing.await()
    }

    /** Collects a subscription's messages, so a test can ask for them one at a time. */
    fun reading(subscription: Subscription): Messages = Messages(scope, subscription)

    suspend fun tearDown() {
        clients.forEach { it.close() }
        scope.cancel()
    }
}

/** A subscription's message flow, read the way the Go tests read its channel. */
class Messages(scope: CoroutineScope, subscription: Subscription) {
    private val received = Channel<Message>(Channel.UNLIMITED)
    private val ended = CompletableDeferred<Unit>()

    init {
        scope.launch {
            subscription.messages.collect { received.send(it) }
            ended.complete(Unit)
        }
    }

    suspend fun next(): Message = withTimeoutOrNull(WAIT) { received.receive() } ?: fail("no message arrived")

    suspend fun awaitEnd() {
        withTimeoutOrNull(WAIT) { ended.await() } ?: fail("the message flow never ended")
    }

    suspend fun expectStillOpen() {
        if (withTimeoutOrNull(BRIEFLY) { ended.await() } != null) {
            fail("the message flow ended while a callback was still running")
        }
    }
}

/** A channel a callback drops what it was told into, so a test can wait for it. */
fun <T> reports(): Channel<T> = Channel(Channel.UNLIMITED)

/** Counts calls made from the client's own coroutines, which are not the test's. */
class Counter {
    private val mutex = Mutex()
    private var count = 0

    suspend fun next(): Int = mutex.withLock { ++count }

    suspend fun total(): Int = mutex.withLock { count }
}

suspend fun <T> Channel<T>.reported(): T = withTimeoutOrNull(WAIT) { receive() } ?: fail("the callback was never called")

suspend fun <T> Channel<T>.reportedNothing() {
    if (withTimeoutOrNull(BRIEFLY) { receive() } != null) {
        fail("the callback was called and should not have been")
    }
}

suspend fun Job.awaitDone(what: String) {
    withTimeoutOrNull(WAIT) { join() } ?: fail(what)
}

suspend fun Job.expectStillRunning(what: String) {
    if (withTimeoutOrNull(BRIEFLY) { join() } != null) {
        fail(what)
    }
}

/** The first failure of type [T] in the chain, the way Go's `errors.As` reads through a wrap. */
inline fun <reified T : Throwable> Throwable?.causedBy(): T? {
    var failure = this
    while (failure != null) {
        if (failure is T) {
            return failure
        }
        failure = failure.cause
    }

    return null
}

inline fun <reified T : Throwable> assertCausedBy(failure: Throwable?, message: String = "expected a ${T::class.simpleName}"): T =
    failure.causedBy<T>() ?: fail("$message, got $failure")

fun assertWraps(failure: Throwable?, expected: Throwable) {
    var current = failure
    while (current != null) {
        if (current === expected) {
            return
        }
        current = current.cause
    }

    fail("expected $failure to wrap $expected")
}
