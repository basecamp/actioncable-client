package com.basecamp.actioncable

import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.concurrent.Volatile

/**
 * One channel subscription on a client. Read what the channel sends from
 * [messages], and talk back with [perform] or [send].
 */
class Subscription internal constructor(
    private val client: ActionCableClient,
    scope: CoroutineScope,
    /**
     * The JSON identifier string the server knows this subscription by, and the
     * one it echoes back on everything it sends here.
     */
    val key: String,
    buffer: Int,
    private val onConnected: (suspend (reconnected: Boolean) -> Unit)?,
    private val onDisconnected: (suspend (willReconnect: Boolean) -> Unit)?,
    private val onRejected: (suspend () -> Unit)?,
) {
    internal val confirmed: CompletableJob = Job()
    internal val rejected: CompletableJob = Job()

    private val inbox = Channel<Message>(buffer)
    private val callbacks = Dispatcher(scope) { inbox.close() }

    /** Guards the inbox, which anyone may close by unsubscribing while the connection is delivering to it. */
    private val sendMutex = Mutex()

    @Volatile
    private var closed = false

    /**
     * Why the subscription ended: an [UnsubscribedException], a
     * [RejectedException], or whatever stopped the client. It is null while the
     * subscription is live.
     */
    @Volatile
    var error: Throwable? = null
        private set

    /**
     * Everything the channel broadcasts or transmits to this subscription. It
     * ends when the subscription is unsubscribed, rejected, or the client
     * stops, once the last callback has returned — [error] says which it was.
     *
     * Collect it promptly, and from one collector. Messages that arrive with
     * the buffer full are dropped and logged rather than stalling the
     * connection; a slow consumer wants a bigger `messageBuffer` on the client.
     */
    val messages: Flow<Message> = inbox.receiveAsFlow()

    /**
     * Invokes an action on the channel — the equivalent of the JavaScript
     * client's `perform`. [data] must have a JSON object form, and may be null.
     */
    suspend fun perform(action: String, data: Any? = null) {
        client.send(Command(CommandName.MESSAGE, key, performPayload(action, data)))
    }

    /**
     * Delivers [data] to the channel as-is, without naming an action. Rails
     * routes it to the channel's `receive` method.
     */
    suspend fun send(data: Any?) {
        client.send(Command(CommandName.MESSAGE, key, jsonOf(data) { "the data for $key" }.toString()))
    }

    /**
     * Tells the server to drop the subscription and ends [messages]. It takes
     * no scope of its own: the command goes out on the client's, so it works
     * from a coroutine that is already being cancelled — which, at teardown, is
     * usually the one at hand.
     */
    suspend fun unsubscribe() {
        val (last, _) = client.forget(this, UnsubscribedException())
        if (last) {
            client.send(Command(CommandName.UNSUBSCRIBE, key))
        }
    }

    private fun performPayload(action: String, data: Any?): String {
        val fields = jsonOf(data) { "the data for $action" }
        if (data != null && fields !is JsonObject) {
            throw ActionCableException("actioncable: data for \"$action\" must have a JSON object form")
        }

        val payload = fields as? JsonObject ?: JsonObject(emptyMap())

        return sortedJsonObject(payload + ("action" to JsonPrimitive(action))).toString()
    }

    /**
     * Passes the server's verdict on. A holder that unsubscribed between the
     * registration's holders being listed and this call has nothing to hear.
     */
    internal suspend fun confirm(reconnected: Boolean) {
        if (closed) {
            return
        }

        // The callback is queued before the verdict is published: a subscribe
        // woken by the verdict may unsubscribe at once, and that must not get
        // ahead of the callback for the event that woke it.
        onConnected?.let { callback -> callbacks.dispatch { callback(reconnected) } }
        confirmed.complete()
    }

    internal suspend fun reject() {
        onRejected?.let { callback -> callbacks.dispatch { callback() } }
        rejected.complete()
        close(rejection())
    }

    internal fun rejection(): RejectedException = RejectedException(key)

    internal suspend fun disconnect(willReconnect: Boolean) {
        onDisconnected?.let { callback -> callbacks.dispatch { callback(willReconnect) } }
    }

    internal suspend fun deliver(message: Message): Boolean = sendMutex.withLock {
        // A closed subscription has nothing left to receive, and nothing to report.
        if (closed) {
            true
        } else {
            inbox.trySend(message).isSuccess
        }
    }

    /**
     * Ends the subscription for the reason given. Deliveries stop at once;
     * [messages] itself ends from the callback coroutine, after the callbacks
     * already queued have run, so a collector that sees it end knows no
     * callback is behind it.
     */
    internal suspend fun close(reason: Throwable) {
        sendMutex.withLock {
            if (!closed) {
                closed = true
                error = reason
            }
        }

        callbacks.stop()
    }
}

/**
 * The server's one subscription for an identifier, and every [Subscription]
 * here that shares it. Rails keeps one subscription per identifier per
 * connection and says nothing to a second subscribe for it, so the subscribe
 * command, its verdict, and the retries until then belong to the identifier
 * rather than to each holder. The client's mutex guards it.
 */
internal class Registration {
    val holders = mutableListOf<Subscription>()

    /**
     * Set while a subscribe is out on the connection in hand with no verdict
     * yet, and [confirmed] once the server said yes on it. Both clear when the
     * connection drops: the next one starts over. A registration starts out
     * pending, since the subscribe goes out right behind it.
     */
    var pending = true
    var confirmed = false
}
