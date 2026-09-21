package com.basecamp.actioncable

import com.basecamp.actioncable.testing.ClosedByTheServer
import com.basecamp.actioncable.testing.FakeProtocol
import com.basecamp.actioncable.testing.FakeTransport
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds

class ConnectingTest {
    @Test
    fun `connect waits for the welcome`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)

        val connecting = connecting(client)
        val conn = transport.accept()
        connecting.expectStillRunning("connect returned before the welcome")

        conn.welcome()
        connecting.await()
        assertTrue(client.isConnected, "client is not connected after the welcome")
    }

    @Test
    fun `connect retries until the server answers`() = cableTest {
        val transport = FakeTransport()
        transport.failNextDial(RuntimeException("connection refused"))
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)

        val connecting = connecting(client)
        transport.accept().welcome()

        connecting.await()
    }

    @Test
    fun `stale connection is replaced`() = cableTest {
        val transport = FakeTransport()
        val client =
            client(
                transport,
                staleAfter = 75.milliseconds,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
            )

        val connecting = connecting(client)
        transport.accept().welcome()
        connecting.await()

        // Say nothing at all: no pings, no messages. The connection goes stale.
        transport.accept().welcome()
    }

    @Test
    fun `server disconnect without reconnect stops the client`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        conn.push("""{"type":"disconnect","reason":"unauthorized","reconnect":false}""")

        transport.refuseDial()
        assertFalse(client.isConnected, "client is still connected after being told to go away")

        val failure = assertFailsWith<DisconnectException> { client.subscribe(room()) }
        assertEquals(DisconnectReason.UNAUTHORIZED, failure.reason)
    }

    @Test
    fun `server disconnect with reconnect dials again`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)
        val conn = welcomed(client, transport)

        conn.push("""{"type":"disconnect","reason":"server_restart","reconnect":true}""")

        transport.accept().welcome()
    }

    @Test
    fun `client offers every protocol and the sentinel`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, protocols = listOf(V1Json, FakeProtocol("actioncable-v2-json", "v2:")))

        welcomed(client, transport)

        assertEquals(
            listOf(SUBPROTOCOL_V1_JSON, "actioncable-v2-json", SUBPROTOCOL_UNSUPPORTED),
            transport.dialedWith.subprotocols,
        )
    }

    @Test
    fun `additional protocols are offered first`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, additionalProtocols = listOf(FakeProtocol("actioncable-v2-json", "v2:")))

        welcomed(client, transport)

        assertEquals(
            listOf("actioncable-v2-json", SUBPROTOCOL_V1_JSON, SUBPROTOCOL_UNSUPPORTED),
            transport.dialedWith.subprotocols,
        )
    }

    @Test
    fun `client speaks the protocol the server picked`() = cableTest {
        val transport = FakeTransport(subprotocol = "actioncable-v2-json")
        val client = client(transport, protocols = listOf(V1Json, FakeProtocol("actioncable-v2-json", "v2:")))

        val conn = welcomed(client, transport)
        subscribing(client)

        val sent = conn.sent().decodeToString()
        assertTrue(sent.startsWith("v2:"), "expected the negotiated protocol to encode the subscribe, got $sent")
    }

    @Test
    fun `unsupported sentinel stops the client`() = cableTest {
        val transport = FakeTransport(subprotocol = SUBPROTOCOL_UNSUPPORTED)
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)

        assertFailsWith<UnsupportedSubprotocolException> { client.connect() }

        transport.accept()
        transport.refuseDial()
    }

    @Test
    fun `no protocols stops the client`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, protocols = emptyList())

        assertFailsWith<NoProtocolsException> { client.connect() }

        transport.refuseDial()
    }

    @Test
    fun `unsupported subprotocol stops the client`() = cableTest {
        val transport = FakeTransport(subprotocol = "actioncable-v9-telepathy")
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)

        assertFailsWith<UnsupportedSubprotocolException> { client.connect() }

        transport.accept()
        transport.refuseDial()
    }

    @Test
    fun `connect after close reports why it stopped`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)
        welcomed(client, transport)

        client.close()

        assertFailsWith<ClosedException> { client.connect() }
        transport.refuseDial()
    }

    @Test
    fun `close before connect leaves the client dead`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport)

        client.close()

        assertFailsWith<ClosedException> { client.connect() }
        assertFalse(client.isConnected, "a client closed before it started reports itself connected")
        transport.refuseDial()
    }

    @Test
    fun `first connection is not a reconnect`() = cableTest {
        val transport = FakeTransport()
        transport.failNextDial(RuntimeException("connection refused"))
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)

        val connecting = connecting(client)
        val conn = transport.accept()
        conn.welcome()
        connecting.await()

        val connections = reports<Boolean>()
        val subscribing = subscribing(client, onConnected = { connections.send(it) })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()

        assertFalse(connections.reported(), "a first connection that took two dials reported itself as a reconnect")
    }

    @Test
    fun `origin defaults to the cable URL`() = cableTest {
        val origins =
            mapOf(
                "wss://cable.example.com/cable" to "https://cable.example.com",
                "ws://cable.example.com:3000/cable" to "http://cable.example.com:3000",
                "wss://cable.example.com:8443/cable" to "https://cable.example.com:8443",
            )

        // Rails compares Origin against the host it serves on, and turns
        // down a request that carries no Origin at all.
        origins.forEach { (url, origin) ->
            val transport = FakeTransport()
            val client = client(transport, url = url)

            welcomed(client, transport)

            assertEquals(origin, transport.dialedWith.headers["Origin"], url)
        }
    }

    @Test
    fun `explicit origin wins`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, origin = "https://app.example.com")

        welcomed(client, transport)

        assertEquals("https://app.example.com", transport.dialedWith.headers["Origin"])
    }

    @Test
    fun `header is copied`() = cableTest {
        val transport = FakeTransport()
        val given = mutableMapOf("Cookie" to listOf("session=secret"))
        val client = client(transport, headers = Headers.from(given))

        given["Cookie"] = listOf("session=tampered")

        welcomed(client, transport)

        assertEquals("session=secret", transport.dialedWith.headers["Cookie"], "expected the header as it was given")
    }

    @Test
    fun `every dial asks for the header again`() = cableTest {
        val transport = FakeTransport()
        transport.failNextDial(RuntimeException("connection refused"))

        val dials = Counter()
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                headers = Headers.of("Origin" to "https://app.example.com"),
                buildHeaders = { Headers.of("Authorization" to "Bearer token-${dials.next()}") },
            )

        welcomed(client, transport)

        val dialed = transport.dialedWith.headers
        assertEquals("Bearer token-2", dialed["Authorization"], "expected the redial to carry the credentials it asked for then")
        assertEquals("https://app.example.com", dialed["Origin"], "expected the headers set once to survive")
    }

    @Test
    fun `a terminal dial error stops the initial connection`() = cableTest {
        val transport = FakeTransport()
        val denied = RuntimeException("connection denied")
        transport.failNextDial(denied)
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                stopOnError = { it === denied },
            )

        // Coroutines hand the caller a copy of the failure with the
        // original as its cause, so what the client recorded is what to
        // compare against and the thrown one has to be read through.
        assertWraps(assertFailsWith<RuntimeException> { client.connect() }, denied)
        assertSame(denied, client.error)
        transport.refuseDial()
    }

    @Test
    fun `a non-terminal connection error still reconnects`() = cableTest {
        val signedOut = RuntimeException("sign in again")
        val transport = FakeTransport()
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                stopOnError = { it === signedOut },
            )
        val conn = welcomed(client, transport)

        conn.close()
        transport.accept().welcome()

        assertNull(client.error, "a retryable error stopped the client")
    }

    @Test
    fun `a terminal connection error stops subscriptions`() = cableTest {
        val transport = FakeTransport()
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                stopOnError = { it is ClosedByTheServer },
            )
        val conn = welcomed(client, transport)

        val disconnections = reports<Boolean>()
        val subscribing = subscribing(client, onDisconnected = { disconnections.send(it) })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        val subscription = subscribing.await()
        val messages = reading(subscription)

        conn.close()

        assertFalse(disconnections.reported(), "onDisconnected promised a reconnect after a terminal error")
        client.done.awaitDone("client kept reconnecting after the terminal connection error")
        assertIs<ClosedByTheServer>(client.error)
        messages.awaitEnd()
        assertIs<ClosedByTheServer>(subscription.error)
        transport.refuseDial()
    }

    @Test
    fun `a terminal header error stops the initial connection`() = cableTest {
        val transport = FakeTransport()
        val signedOut = RuntimeException("sign in again")
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                stopOnError = { it === signedOut },
                buildHeaders = { throw signedOut },
            )

        assertWraps(assertFailsWith<RuntimeException> { client.connect() }, signedOut)
        assertSame(signedOut, client.error)
        transport.refuseDial()
    }

    @Test
    fun `a terminal header error stops a reconnect`() = cableTest {
        val transport = FakeTransport()
        val signedOut = RuntimeException("sign in again")
        val headers = Counter()
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                stopOnError = { it === signedOut },
                buildHeaders = {
                    if (headers.next() == 1) {
                        Headers.of("Authorization" to "Bearer token")
                    } else {
                        throw signedOut
                    }
                },
            )

        welcomed(client, transport).close()

        client.done.awaitDone("client kept reconnecting after the terminal header error")
        assertSame(signedOut, client.error)
        assertEquals(2, headers.total(), "expected one initial header and one failed reconnect header")
        transport.refuseDial()
    }

    @Test
    fun `a dial is turned down when the header cannot be built`() = cableTest {
        val transport = FakeTransport()

        val asked = Counter()
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                buildHeaders = {
                    if (asked.next() == 1) {
                        throw RuntimeException("no credentials to hand over")
                    }

                    Headers.of("Authorization" to "Bearer token")
                },
            )

        welcomed(client, transport)

        assertEquals(
            "Bearer token",
            transport.dialedWith.headers["Authorization"],
            "expected the client to dial again after the header failed",
        )
    }

    @Test
    fun `a connect that runs out of time stops the client`() = cableTest {
        val transport = FakeTransport()
        transport.failNextDial(RuntimeException("connection refused"))
        val client = client(transport, initialBackoff = 1.hours, longestBackoff = 1.hours)

        assertFailsWith<CancellationException> {
            withTimeout(50.milliseconds) { client.connect() }
        }

        val abandoned = assertCausedBy<ConnectCancelledException>(client.error)
        assertContains(
            abandoned.cause?.message.orEmpty(),
            "connection refused",
            message = "expected the failure to say what the client was waiting out",
        )
        client.done.awaitDone("client kept running after connect gave up")
        assertFailsWith<ConnectCancelledException> { client.connect() }
        transport.refuseDial()
    }

    @Test
    fun `a connect that runs out of time names the header that failed`() = cableTest {
        val transport = FakeTransport()
        val noCredentials = RuntimeException("no credentials to hand over")
        val client =
            client(
                transport,
                initialBackoff = 1.milliseconds,
                longestBackoff = 1.milliseconds,
                buildHeaders = { throw noCredentials },
            )

        assertFailsWith<CancellationException> {
            withTimeout(50.milliseconds) { client.connect() }
        }

        assertCausedBy<ConnectCancelledException>(client.error)
        assertWraps(client.error, noCredentials)
        transport.refuseDial()
    }

    @Test
    fun `max attempts stops the client`() = cableTest {
        val transport = FakeTransport()
        val refused = RuntimeException("connection refused")
        transport.failNextDial(refused)
        transport.failNextDial(refused)
        val client =
            client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds, maxAttempts = 2)

        val failure = assertFailsWith<GaveUpException> { client.connect() }
        assertWraps(failure, refused)

        client.done.awaitDone("client kept running after its attempts ran out")
        assertIs<GaveUpException>(client.error)
        transport.refuseDial()
    }

    @Test
    fun `a welcome resets the attempt count`() = cableTest {
        val transport = FakeTransport()
        transport.failNextDial(RuntimeException("connection refused"))
        val client =
            client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds, maxAttempts = 3)
        val conn = welcomed(client, transport)

        // Losing the connection is the first failed attempt of the outage,
        // and the refused redial the second. Had the failure before the
        // welcome still counted, that would have been the third.
        transport.failNextDial(RuntimeException("connection refused"))
        conn.close()

        transport.accept().welcome()
        assertNull(client.error, "a failure before the welcome should not count against the outage after it")
    }

    @Test
    fun `giving up tells subscriptions the client is not coming back`() = cableTest {
        val transport = FakeTransport()
        val client =
            client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds, maxAttempts = 1)
        val conn = welcomed(client, transport)

        val disconnections = reports<Boolean>()
        val subscribing = subscribing(client, onDisconnected = { disconnections.send(it) })
        conn.expectCommand(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
        conn.confirm(ROOM_IDENTIFIER)
        subscribing.await()

        // Losing the connection is the only attempt allowed, so the client
        // is done for, and the subscription should hear that rather than a
        // promise to return.
        conn.close()

        assertFalse(disconnections.reported(), "onDisconnected promised a reconnect the client was about to give up on")
        client.done.awaitDone("client kept running after its attempts ran out")
        assertIs<GaveUpException>(client.error)
        transport.refuseDial()
    }

    @Test
    fun `done and error follow the client`() = cableTest {
        val transport = FakeTransport()
        val client = client(transport, initialBackoff = 1.milliseconds, longestBackoff = 1.milliseconds)

        assertNull(client.error, "a client that hasn't started has nothing to report")
        val conn = welcomed(client, transport)
        assertNull(client.error, "a running client has nothing to report")
        assertFalse(client.done.isCompleted, "done completed on a running client")

        conn.push("""{"type":"disconnect","reason":"unauthorized","reconnect":false}""")

        client.done.awaitDone("done never completed after the server hung up for good")
        assertEquals(DisconnectReason.UNAUTHORIZED, assertCausedBy<DisconnectException>(client.error).reason)
    }
}
