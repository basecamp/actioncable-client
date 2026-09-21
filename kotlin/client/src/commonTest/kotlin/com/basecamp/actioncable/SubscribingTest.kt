package com.basecamp.actioncable

import com.basecamp.actioncable.testing.FakeTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

private const val OTHER_IDENTIFIER = """{"channel":"OtherChannel"}"""

@Serializable
private data class Said(val body: String)

class SubscribingTest {
    @Test
    fun `subscribe receives messages`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val connections = reports<Boolean>()
        val subscribing = subscribing(client, onConnected = { connections.send(it) })

        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)

        val subscription = subscribing.await()
        val messages = reading(subscription)
        assertFalse(connections.reported(), "first connection reported itself as a reconnect")

        conn.transmit(ROOM_IDENTIFIER, """{"body":"Hello!"}""")

        assertEquals("Hello!", messages.next().decode<Said>().body)
    }

    @Test
    fun `subscribe rejected`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val rejections = reports<Unit>()
        val subscribing = subscribing(client, onRejected = { rejections.send(Unit) })

        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.reject(ROOM_IDENTIFIER)

        assertFailsWith<RejectedException> { subscribing.await() }
        rejections.reported()
    }

    @Test
    fun `perform sends an action`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        subscription.perform("speak", mapOf("body" to "Hello!"))

        val command = conn.expectCommand(CommandName.MESSAGE, ROOM_IDENTIFIER)
        assertEquals("""{"action":"speak","body":"Hello!"}""", command.data, "expected the action alongside the data")
    }

    @Test
    fun `send delivers data without an action`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        subscription.send(mapOf("body" to "Hello!"))

        val command = conn.expectCommand(CommandName.MESSAGE, ROOM_IDENTIFIER)
        assertEquals("""{"body":"Hello!"}""", command.data, "expected the data on its own")
    }

    @Test
    fun `send refuses data that cannot encode`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        assertFailsWith<ActionCableException> { subscription.send(Regex("nope")) }
    }

    @Test
    fun `perform refuses data that is not an object`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        assertFailsWith<ActionCableException> { subscription.perform("speak", listOf("nope")) }
    }

    @Test
    fun `unsubscribe closes messages and tells the server`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)
        val messages = reading(subscription)

        subscription.unsubscribe()
        conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)

        messages.awaitEnd()
    }

    @Test
    fun `reconnect resubscribes`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        val connections = reports<Boolean>()
        val disconnections = reports<Boolean>()
        val subscribing =
            subscribing(
                client,
                onConnected = { connections.send(it) },
                onDisconnected = { disconnections.send(it) },
            )
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()
        connections.reported()

        conn.close()

        assertTrue(disconnections.reported(), "disconnect reported that the client would not reconnect")

        val reconnected = transport.accept()
        reconnected.welcome()
        reconnected.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        reconnected.confirm(ROOM_IDENTIFIER)

        assertTrue(connections.reported(), "expected the confirmation after a reconnect to report reconnected")
    }

    @Test
    fun `unconfirmed subscribe is retried`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, subscribeRetry = 20.milliseconds)
        val conn = welcomed(client, transport)

        val subscribing = subscribing(client)
        conn.dropCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()
    }

    @Test
    fun `subscribe before connect`() = cableTest {
        val client = client(FakeTransport())

        assertFailsWith<NotConnectedException> { client.subscribe(room()) }
    }

    @Test
    fun `close closes subscriptions`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)
        val messages = reading(subscription)

        client.close()

        messages.awaitEnd()
        assertFailsWith<NotConnectedException> { subscription.perform("speak") }
    }

    @Test
    fun `messages arrive on every subscription sharing an identifier`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val first = subscribed(client, conn)
        val second = client.subscribe(room())
        val toFirst = reading(first)
        val toSecond = reading(second)

        conn.transmit(ROOM_IDENTIFIER, """{"body":"Hello!"}""")

        assertEquals("""{"body":"Hello!"}""", toFirst.next().toString(), "expected the broadcast")
        assertEquals("""{"body":"Hello!"}""", toSecond.next().toString(), "expected the broadcast")

        // Only the last subscription standing tells the server to unsubscribe.
        first.unsubscribe()
        conn.expectNoCommand()

        second.unsubscribe()
        conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)
    }

    @Test
    fun `subscribe to a confirmed identifier sends nothing`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        subscribed(client, conn)

        // Rails has the identifier already and would ignore a second
        // subscribe, so the one confirmation it gave stands for this
        // subscription too.
        val connections = reports<Boolean>()
        client.subscribe(room(), onConnected = { connections.send(it) })

        assertFalse(connections.reported(), "a subscription joining a confirmed identifier reported itself as a reconnect")
        conn.expectNoCommand()
    }

    @Test
    fun `subscribers join an in-flight subscribe`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val first = subscribing(client)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        val second = subscribing(client)
        val third = subscribing(client)
        conn.expectNoCommand()

        conn.confirm(ROOM_IDENTIFIER)

        listOf(first, second, third).forEach { it.await() }
    }

    @Test
    fun `subscribers joining an in-flight subscribe share its rejection`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val first = subscribing(client)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        val second = subscribing(client)
        conn.expectNoCommand()

        conn.reject(ROOM_IDENTIFIER)

        assertFailsWith<RejectedException> { first.await() }
        assertFailsWith<RejectedException> { second.await() }
    }

    @Test
    fun `subscribers joining an in-flight subscribe follow it through a reconnect`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        val first = subscribing(client)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        val second = subscribing(client)
        conn.expectNoCommand()

        conn.close()

        val reconnected = transport.accept()
        reconnected.welcome()
        reconnected.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        reconnected.expectNoCommand()
        reconnected.confirm(ROOM_IDENTIFIER)

        first.await()
        second.await()
    }

    @Test
    fun `cancelling the only in-flight subscribe tells the server`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val subscribing = scope.async { client.subscribe(room()) }
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

        // The server has the subscription whether or not anyone here still
        // wants it, and would ignore the next subscribe for it unless told
        // to let go.
        subscribing.cancel()
        assertFailsWith<CancellationException> { subscribing.await() }
        conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)
        conn.expectNoCommand()

        subscribed(client, conn)
    }

    @Test
    fun `cancelling a subscriber joining an in-flight subscribe leaves the first waiting`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val first = subscribing(client)
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

        val joining = scope.async { client.subscribe(room()) }
        conn.expectNoCommand()

        joining.cancel()
        assertFailsWith<CancellationException> { joining.await() }
        conn.expectNoCommand()

        conn.confirm(ROOM_IDENTIFIER)
        first.await()
    }

    @Test
    fun `close from on disconnected`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        val closed = reports<Unit>()
        val subscribing =
            subscribing(client, onDisconnected = {
                client.close()
                closed.send(Unit)
            })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()

        conn.close()

        closed.reported()
    }

    @Test
    fun `subscribe from on connected`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val subscribing =
            subscribing(client, onConnected = {
                scope.launch { client.subscribe(Identifier("OtherChannel")) }
            })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()

        conn.expectCommand(CommandName.SUBSCRIBE, OTHER_IDENTIFIER)
        conn.confirm(OTHER_IDENTIFIER)
    }

    @Test
    fun `unsubscribe while messages arrive`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, messageBuffer = 1)
        val conn = welcomed(client, transport)

        repeat(50) {
            val subscription = subscribed(client, conn)

            val pushed = scope.async { conn.transmit(ROOM_IDENTIFIER, """{"body":"Hello!"}""") }

            subscription.unsubscribe()
            pushed.await()
            conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)
        }
    }

    @Test
    fun `perform before the welcome is refused`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        conn.close()
        transport.accept()

        // The connection is up again but not yet welcomed, and the server
        // throws away anything sent that early, so a command then is not a
        // command landed.
        assertFailsWith<NotConnectedException> { subscription.perform("speak") }
    }

    @Test
    fun `repeated confirmation connects once`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val connections = reports<Boolean>()
        val subscribing = subscribing(client, onConnected = { connections.send(it) })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()
        connections.reported()

        conn.confirm(ROOM_IDENTIFIER)

        connections.reportedNothing()
    }

    @Test
    fun `an unsubscribe during a resubscribe goes out after it`() = cableTest {
        val transport = FakeTransport(writeBuffer = 0)
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        subscribed(client, conn)
        val subscribing = subscribing(client, Identifier("OtherChannel"))
        conn.expectCommand(CommandName.SUBSCRIBE, OTHER_IDENTIFIER)
        conn.confirm(OTHER_IDENTIFIER)
        val other = subscribing.await()

        conn.close()

        // The welcome sets the client resubscribing both. With nobody
        // reading yet it is stuck mid-list on the first write, which is
        // when the unsubscribe arrives and queues up behind it. Had it
        // slipped in ahead of the second subscribe, the server would have
        // been left holding OtherChannel with no one here to answer for it.
        val reconnected = transport.accept()
        reconnected.welcome()
        reconnected.writing()
        val unsubscribing = scope.async { other.unsubscribe() }

        val first = reconnected.command()
        val second = reconnected.command()
        assertEquals(
            listOf(CommandName.SUBSCRIBE.wire, CommandName.SUBSCRIBE.wire),
            listOf(first.name, second.name),
            "expected both resubscribes before anything else",
        )
        assertEquals(
            setOf(ROOM_IDENTIFIER, OTHER_IDENTIFIER),
            setOf(first.identifier, second.identifier),
        )
        reconnected.expectCommand(CommandName.UNSUBSCRIBE, OTHER_IDENTIFIER)
        unsubscribing.await()
    }

    @Test
    fun `messages close after the last callback returns`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val entered = CompletableDeferred<Unit>()
        val release = Channel<Unit>()
        val subscribing =
            subscribing(client, onDisconnected = {
                entered.complete(Unit)
                release.receive()
            })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        val subscription = subscribing.await()
        val messages = reading(subscription)

        client.close()
        entered.await()

        messages.expectStillOpen()

        release.send(Unit)

        messages.awaitEnd()
        assertIs<ClosedException>(subscription.error)
    }

    @Test
    fun `unsubscribed subscription reports why`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)

        assertNull(subscription.error, "a live subscription has nothing to report")

        subscription.unsubscribe()
        conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)

        assertIs<UnsubscribedException>(subscription.error)
    }

    @Test
    fun `rejection after a reconnect reports why`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)
        val subscription = subscribed(client, conn)
        val messages = reading(subscription)

        conn.close()

        val reconnected = transport.accept()
        reconnected.welcome()
        reconnected.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        reconnected.reject(ROOM_IDENTIFIER)

        messages.awaitEnd()
        assertIs<RejectedException>(subscription.error)
    }

    @Test
    fun `unsubscribe needs no scope of its own`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        val conn = welcomed(client, transport)

        val subscribing = scope.async { client.subscribe(room()) }
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        val subscription = subscribing.await()

        // The coroutine the subscription was made under is long gone by the
        // time the caller is tearing down, and that must not stop the
        // hang-up from going out.
        subscribing.cancel()

        subscription.unsubscribe()
        conn.expectCommand(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)
    }
}
