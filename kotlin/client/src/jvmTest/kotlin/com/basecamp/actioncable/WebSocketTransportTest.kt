package com.basecamp.actioncable

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The built-in transport against a real loopback server that does the upgrade
 * by hand. Everything here goes over a socket, which is the point: it is what
 * proves the WebSocket code rather than the client's idea of it.
 */
class WebSocketTransportTest {
    @Test
    fun `negotiates the subprotocol`() = transportTest { server ->
        val conn = dial(server, DialOptions(subprotocols = listOf(SUBPROTOCOL_V1_JSON)))

        assertEquals(SUBPROTOCOL_V1_JSON, conn.subprotocol)
        assertEquals(
            SUBPROTOCOL_V1_JSON,
            server.accept().request.header("Sec-WebSocket-Protocol"),
            "expected the client to offer the subprotocol",
        )
    }

    @Test
    fun `sends headers`() = transportTest { server ->
        dial(
            server,
            DialOptions(
                subprotocols = listOf(SUBPROTOCOL_V1_JSON),
                headers = Headers.of("Cookie" to "session=secret", "Origin" to "https://example.com"),
            ),
        )

        val request = server.accept().request
        assertEquals("session=secret", request.header("Cookie"))
        assertEquals("https://example.com", request.header("Origin"))
        assertEquals(WebSocketTransport.USER_AGENT, request.header("User-Agent"))
        assertEquals("/cable", request.path)
    }

    @Test
    fun `sends the caller's user agent`() = transportTest { server ->
        dial(server, DialOptions(headers = Headers.of("User-Agent" to "custom-agent")))

        assertEquals("custom-agent", server.accept().request.header("User-Agent"))
    }

    @Test
    fun `neutralizes header injection`() = transportTest { server ->
        dial(server, DialOptions(headers = Headers.of("Authorization" to "Bearer token\r\nX-Injected: gotcha")))

        val request = server.accept().request
        assertNull(request.header("X-Injected"), "expected the newlines to be neutralized")
        assertContains(
            request.header("Authorization").orEmpty(),
            "Bearer token",
            message = "expected the authorization header to survive",
        )
    }

    @Test
    fun `round trips messages`() = transportTest { server ->
        val conn = dial(server, DialOptions(subprotocols = listOf(SUBPROTOCOL_V1_JSON)))
        val peer = server.accept()

        conn.write("""{"command":"subscribe"}""".encodeToByteArray())
        assertEquals("""{"command":"subscribe"}""", peer.read())

        peer.write(OP_TEXT, """{"type":"welcome"}""")
        assertEquals("""{"type":"welcome"}""", conn.readWithin().decodeToString())
    }

    @Test
    fun `answers pings`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        peer.write(OP_PING, "beat")
        peer.write(OP_TEXT, "after the ping")

        assertEquals("after the ping", conn.readWithin().decodeToString())

        val frame = peer.readFrame()
        assertEquals(OP_PONG, frame.opcode, "expected a pong")
        assertEquals("beat", frame.text, "expected the pong to carry the ping payload")
    }

    @Test
    fun `reassembles fragments`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        peer.writeFragment(OP_TEXT, "one ".encodeToByteArray(), false)
        peer.writeFragment(OP_PING, "interleaved".encodeToByteArray(), true)
        peer.writeFragment(OP_CONTINUATION, "message".encodeToByteArray(), true)

        assertEquals("one message", conn.readWithin().decodeToString())
    }

    @Test
    fun `reads large messages`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        val long = "cable".repeat(30_000)
        peer.write(OP_TEXT, long)
        assertEquals(long, conn.readWithin().decodeToString())

        conn.write(long.encodeToByteArray())
        assertEquals(long, peer.read())
    }

    @Test
    fun `refuses oversized messages`() = transportTest { server ->
        val conn = WebSocketTransport(maxMessageSize = 8).dial(server.url, DialOptions())

        server.accept().write(OP_TEXT, "far too long for eight bytes")

        assertFailsWith<MessageTooBigException> { conn.readWithin() }
    }

    @Test
    fun `refuses oversized fragmented messages`() = transportTest { server ->
        val conn = WebSocketTransport(maxMessageSize = 8).dial(server.url, DialOptions())

        val peer = server.accept()
        peer.writeFragment(OP_TEXT, "five ".encodeToByteArray(), false)
        peer.writeFragment(OP_CONTINUATION, "more".encodeToByteArray(), true)

        assertFailsWith<MessageTooBigException> { conn.readWithin() }
    }

    @Test
    fun `reports server close`() = transportTest { server ->
        val conn = dial(server, DialOptions())

        server.accept().write(OP_CLOSE, closePayload(4401, "unauthorized"))

        val closed = assertFailsWith<CloseException> { conn.readWithin() }
        assertEquals(4401, closed.code)
        assertEquals("unauthorized", closed.reason)
    }

    @Test
    fun `reports a server close without a status`() = transportTest { server ->
        val conn = dial(server, DialOptions())

        server.accept().write(OP_CLOSE, ByteArray(0))

        val closed = assertFailsWith<CloseException> { conn.readWithin() }
        assertEquals(1005, closed.code)
        assertEquals("", closed.reason)
    }

    @Test
    fun `closes with a status`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        val closer = assertIs<StatusCloser>(conn, "the built-in connection should implement StatusCloser")
        closer.closeWithStatus(4000, "done here")

        val frame = peer.readFrame()
        assertEquals(OP_CLOSE, frame.opcode)
        assertEquals(4000, statusOf(frame.payload))
        assertEquals("done here", frame.payload.decodeToString(2, frame.payload.size))
    }

    @Test
    fun `truncates a close reason to fit the frame`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        (conn as StatusCloser).closeWithStatus(4000, "r".repeat(200))

        val frame = peer.readFrame()
        assertEquals(OP_CLOSE, frame.opcode)
        assertEquals(125, frame.payload.size, "a control frame's payload is at most 125 bytes")
    }

    @Test
    fun `refuses a non-upgrade response`() = runTest(timeout = 30.seconds) {
        withContext(Dispatchers.Default) {
            LoopbackServer(refuseWith = notFound()).use { server ->
                val refused =
                    assertFailsWith<HandshakeException> { WebSocketTransport().dial(server.url, DialOptions()) }
                assertEquals(404, refused.statusCode)
            }
        }
    }

    @Test
    fun `does not follow a redirect`() = runTest(timeout = 30.seconds) {
        withContext(Dispatchers.Default) {
            LoopbackServer(refuseWith = redirect()).use { server ->
                val refused =
                    assertFailsWith<HandshakeException> { WebSocketTransport().dial(server.url, DialOptions()) }
                assertEquals(302, refused.statusCode)
            }
        }
    }

    @Test
    fun `refuses a bad accept key`() = runTest(timeout = 30.seconds) {
        withContext(Dispatchers.Default) {
            LoopbackServer(badAccept = true).use { server ->
                assertFailsWith<ActionCableException> { WebSocketTransport().dial(server.url, DialOptions()) }
            }
        }
    }

    @Test
    fun `honors cancellation`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        server.accept()

        assertFailsWith<CancellationException> {
            withTimeout(50.milliseconds) { conn.read() }
        }
    }

    /** The whole cable dance over an actual WebSocket connection. */
    @Test
    fun `the client over the real transport`() = runTest(timeout = 30.seconds) {
        withContext(Dispatchers.Default) {
            LoopbackServer().use { server ->
                val test = CableTest()
                val client = ActionCableClient(server.url, logger = { println(it) })

                try {
                    val connecting = test.connecting(client)
                    val peer = server.accept()
                    peer.write(OP_TEXT, """{"type":"welcome"}""")
                    connecting.await()

                    val subscribing = test.subscribing(client)
                    assertEquals(
                        """{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}"}""",
                        peer.read(),
                    )
                    peer.write(
                        OP_TEXT,
                        """{"type":"confirm_subscription","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}"}""",
                    )

                    val subscription = subscribing.await()
                    val messages = test.reading(subscription)

                    peer.write(
                        OP_TEXT,
                        """{"identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","message":{"body":"Hello!"}}""",
                    )
                    assertEquals("""{"body":"Hello!"}""", messages.next().toString())

                    subscription.perform("speak", mapOf("body" to "Hi!"))
                    assertEquals(
                        """{"command":"message","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}",""" +
                            """"data":"{\"action\":\"speak\",\"body\":\"Hi!\"}"}""",
                        peer.read(),
                    )
                } finally {
                    client.close()
                    test.tearDown()
                }
            }
        }
    }

    @Test
    fun `refuses a masked server frame`() = transportTest { server ->
        val conn = dial(server, DialOptions())

        // RFC 6455 §5.1: a server must never mask, and a client that sees a
        // masked frame must fail the connection rather than quietly unmask it.
        server.accept().writeMasked(OP_TEXT, """{"type":"welcome"}""".encodeToByteArray())

        assertFails { conn.readWithin() }
    }

    @Test
    fun `replies to a close once`() = transportTest { server ->
        val conn = dial(server, DialOptions())
        val peer = server.accept()

        peer.write(OP_CLOSE, closePayload(1000, ""))
        assertFailsWith<CloseException> { conn.readWithin() }
        conn.close()

        assertEquals(1, peer.closeFrames(), "expected exactly one close frame in reply")
    }
}

/** A transport test with a loopback server up, torn down however the test ends. */
private fun transportTest(body: suspend (LoopbackServer) -> Unit) = runTest(timeout = 30.seconds) {
    withContext(Dispatchers.Default) {
        LoopbackServer().use { body(it) }
    }
}

private suspend fun dial(server: LoopbackServer, options: DialOptions): Conn = WebSocketTransport().dial(server.url, options)

private suspend fun Conn.readWithin(): ByteArray = withTimeout(5.seconds) { read() }

private fun closePayload(code: Int, reason: String): ByteArray =
    byteArrayOf((code shr 8).toByte(), code.toByte()) + reason.encodeToByteArray()

private fun statusOf(payload: ByteArray): Int = (payload[0].toInt() and 0xff) shl 8 or (payload[1].toInt() and 0xff)

private fun notFound(): String =
    "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nno cable here"

private fun redirect(): String = "HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
