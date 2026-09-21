package com.basecamp.actioncable.testing

import com.basecamp.actioncable.Command
import com.basecamp.actioncable.CommandName
import com.basecamp.actioncable.Conn
import com.basecamp.actioncable.DialOptions
import com.basecamp.actioncable.Incoming
import com.basecamp.actioncable.Protocol
import com.basecamp.actioncable.SUBPROTOCOL_V1_JSON
import com.basecamp.actioncable.Transport
import com.basecamp.actioncable.V1Json
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.concurrent.Volatile
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** How long a test will hang around for something that should already have happened. */
val WAIT: Duration = 2.seconds

/**
 * How long a test waits before it believes nothing is coming. Long enough that
 * a busy machine isn't mistaken for a quiet client, short enough that a suite
 * full of them still runs quickly.
 */
val BRIEFLY: Duration = 200.milliseconds

/**
 * Hands out in-memory connections a test plays the server on. It is the same
 * fake the client's own tests are written against, published so an application
 * can drive its cable code without a server.
 *
 * ```
 * val transport = FakeTransport()
 * val client = ActionCableClient("ws://cable.example.com/cable", transport = transport)
 *
 * launch { client.connect() }
 * val server = transport.accept()
 * server.welcome()
 * ```
 *
 * @param subprotocol what the server says it picked.
 * @param writeBuffer how many commands a connection takes before a write waits
 *   on the test reading them. Zero makes every write wait, which lets a test
 *   hold the client mid-write.
 */
class FakeTransport(@Volatile var subprotocol: String = SUBPROTOCOL_V1_JSON, private val writeBuffer: Int = 32) : Transport {
    private val dialed = Channel<FakeConn>(16)
    private val dialErrors = Channel<Throwable>(Channel.UNLIMITED)

    /** The options the client last dialed with. */
    @Volatile
    var dialedWith: DialOptions = DialOptions()
        private set

    override suspend fun dial(url: String, options: DialOptions): Conn {
        dialedWith = options
        dialErrors.tryReceive().getOrNull()?.let { throw it }

        val conn = FakeConn(subprotocol, writeBuffer)
        dialed.send(conn)

        return conn
    }

    /** Turns the next dial down, the way a server that isn't listening would. */
    fun failNextDial(error: Throwable) {
        dialErrors.trySend(error)
    }

    /** The next connection the client opens. */
    suspend fun accept(): FakeConn = withTimeoutOrNull(WAIT) { dialed.receive() } ?: fail("no connection was dialed")

    /** Fails when the client dials at all in the next little while. */
    suspend fun refuseDial() {
        val conn = withTimeoutOrNull(BRIEFLY) { dialed.receive() }
        if (conn != null) {
            fail("expected no connection, got one with subprotocol \"${conn.subprotocol}\"")
        }
    }
}

/**
 * One connection with the test playing the server on the other end. Like Rails
 * it keeps one subscription per identifier: a subscribe for an identifier it
 * has already heard, answered or not, is ignored.
 */
class FakeConn internal constructor(override val subprotocol: String, writeBuffer: Int) : Conn {
    private val incoming = Channel<ByteArray>(Channel.RENDEZVOUS)
    private val outgoing = Channel<ByteArray>(writeBuffer)
    private val closed = CompletableDeferred<Unit>()
    private val subscribed = mutableSetOf<String>()
    private val mutex = Mutex()

    /** Ticks as each write begins, so a test can tell the client is stuck in one before anyone reads what it wrote. */
    private val writes = Channel<Unit>(64)

    override suspend fun read(): ByteArray = select<ByteArray> {
        incoming.onReceive { it }
        closed.onAwait { throw ClosedByTheServer() }
    }

    override suspend fun write(payload: ByteArray) {
        if (ignores(payload)) {
            return
        }

        writes.trySend(Unit)

        select<Unit> {
            outgoing.onSend(payload) { }
            closed.onAwait { throw ClosedByTheServer() }
        }
    }

    override suspend fun close() {
        closed.complete(Unit)
    }

    /** Plays a server frame to the client. */
    suspend fun push(frame: String) {
        val delivered =
            withTimeoutOrNull(WAIT) {
                select<Boolean> {
                    incoming.onSend(frame.encodeToByteArray()) { true }
                    closed.onAwait { fail("connection closed before $frame could be sent") }
                }
            }

        if (delivered == null) {
            fail("client never read $frame")
        }
    }

    suspend fun welcome() {
        push("""{"type":"welcome"}""")
    }

    suspend fun confirm(identifier: String) {
        push("""{"type":"confirm_subscription","identifier":${quote(identifier)}}""")
    }

    /** Turns a subscription down, which also forgets it: the client is free to try again. */
    suspend fun reject(identifier: String) {
        mutex.withLock { subscribed.remove(identifier) }

        push("""{"type":"reject_subscription","identifier":${quote(identifier)}}""")
    }

    /** Broadcasts a message to a subscription, as a channel's `transmit` would. */
    suspend fun transmit(identifier: String, message: String) {
        push("""{"identifier":${quote(identifier)},"message":$message}""")
    }

    /** The next payload the client writes, exactly as it went out. */
    suspend fun sent(): ByteArray = withTimeoutOrNull(WAIT) { outgoing.receive() } ?: fail("client sent nothing")

    /** Waits for the client to start a write, before anyone has read what it wrote. */
    suspend fun writing() {
        withTimeoutOrNull(WAIT) { writes.receive() } ?: fail("client never started a write")
    }

    /** The next command the client sends. Nobody has heard it yet: [command] and [dropCommand] settle that. */
    suspend fun next(): SentCommand = SentCommand.from(sent())

    /** The next command the client sends, taken in the way the server would. */
    suspend fun command(): SentCommand = next().also { hear(it) }

    suspend fun expectCommand(name: CommandName, identifier: String): SentCommand {
        val command = command()
        if (command.name != name.wire || command.identifier != identifier) {
            fail("expected $name for $identifier, got ${command.name} for ${command.identifier}")
        }

        return command
    }

    /**
     * Lets the next command fall on the floor, the way the server drops a
     * subscribe that reaches it before the connection is set up.
     */
    suspend fun dropCommand(name: CommandName, identifier: String) {
        val command = next()
        if (command.name != name.wire || command.identifier != identifier) {
            fail("expected $name for $identifier, got ${command.name} for ${command.identifier}")
        }
    }

    /** Fails when the client sends anything in the next little while. */
    suspend fun expectNoCommand() {
        val payload = withTimeoutOrNull(BRIEFLY) { outgoing.receive() }
        if (payload != null) {
            fail("expected no command, got ${payload.decodeToString()}")
        }
    }

    private suspend fun hear(command: SentCommand) {
        mutex.withLock {
            when (command.name) {
                CommandName.SUBSCRIBE.wire -> subscribed.add(command.identifier)
                CommandName.UNSUBSCRIBE.wire -> subscribed.remove(command.identifier)
            }
        }
    }

    /**
     * Whether the server would drop the command without a word: Rails does that
     * to a second subscribe for an identifier the connection already has.
     */
    private suspend fun ignores(payload: ByteArray): Boolean {
        val command =
            try {
                SentCommand.from(payload)
            } catch (undecodable: Exception) {
                return false
            }

        return mutex.withLock { command.name == CommandName.SUBSCRIBE.wire && command.identifier in subscribed }
    }
}

/** A command the client sent, as the server reads it off the wire. */
class SentCommand(val name: String, val identifier: String, val data: String) {
    companion object {
        private val format = Json { ignoreUnknownKeys = true }

        internal fun from(payload: ByteArray): SentCommand {
            val frame = format.parseToJsonElement(payload.decodeToString()) as JsonObject

            return SentCommand(
                name = frame.stringOf("command"),
                identifier = frame.stringOf("identifier"),
                data = frame.stringOf("data"),
            )
        }

        private fun JsonObject.stringOf(name: String): String = this[name]?.jsonPrimitive?.contentOrNull ?: ""
    }

    override fun toString(): String = "$name $identifier $data"
}

/**
 * Speaks a made-up subprotocol and stamps everything it encodes, so a test can
 * tell which protocol the client settled on.
 */
class FakeProtocol(override val subprotocol: String, private val stamp: String) : Protocol {
    override fun encode(command: Command): ByteArray = stamp.encodeToByteArray() + V1Json.encode(command)

    override fun decode(payload: ByteArray): Incoming = V1Json.decode(payload.decodeToString().removePrefix(stamp).encodeToByteArray())
}

/** What a [FakeConn]'s read and write answer once the test has hung up. */
class ClosedByTheServer : Exception("the fake connection is closed")

private fun quote(value: String): String = JsonPrimitive(value).toString()

private fun fail(message: String): Nothing = throw AssertionError(message)
