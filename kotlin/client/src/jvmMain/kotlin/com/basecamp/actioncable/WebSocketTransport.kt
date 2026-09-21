package com.basecamp.actioncable

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.net.http.WebSocketHandshakeException
import java.nio.ByteBuffer
import java.util.concurrent.CompletionStage
import kotlin.concurrent.Volatile
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.toJavaDuration

/**
 * The built-in transport: the JDK's own WebSocket client, so the library
 * carries no HTTP dependency of its own.
 *
 * The upgrade handshake, masking, ping answering and fragment reassembly are
 * the JDK's business. What this adds is what the client needs on top: the typed
 * handshake, close and oversize failures, a close that can carry a status, and
 * a User-Agent a server can recognize.
 *
 * @param httpClient the client the sockets are opened on. The default never
 *   follows a redirect, so a server answering the upgrade with a 302 is a
 *   [HandshakeException] rather than a silent hop somewhere else.
 * @param handshakeTimeout bounds the upgrade request.
 * @param writeTimeout bounds one write.
 * @param maxMessageSize the largest message accepted. A binary message is
 *   measured in bytes and a text one in characters, which the JDK hands over
 *   without their encoded length; a character is never more than a UTF-8 byte,
 *   so the limit lets a little more text through than it would bytes.
 */
class WebSocketTransport(
    private val httpClient: HttpClient = defaultHttpClient(),
    private val handshakeTimeout: Duration = 10.seconds,
    private val writeTimeout: Duration = 10.seconds,
    private val maxMessageSize: Long = 8L shl 20,
) : Transport {
    companion object {
        const val USER_AGENT = "actioncable-kotlin"

        fun defaultHttpClient(): HttpClient = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build()
    }

    override suspend fun dial(url: String, options: DialOptions): Conn {
        val incoming = WebSocketConn.Incoming(maxMessageSize)
        val builder = httpClient.newWebSocketBuilder().connectTimeout(handshakeTimeout.toJavaDuration())

        options.headers.forEach { name, value -> builder.header(name, value) }
        if (options.headers["User-Agent"] == null) {
            builder.header("User-Agent", USER_AGENT)
        }
        if (options.subprotocols.isNotEmpty()) {
            builder.subprotocols(options.subprotocols.first(), *options.subprotocols.drop(1).toTypedArray())
        }

        val socket =
            try {
                builder.buildAsync(URI.create(url), incoming).await()
            } catch (refused: WebSocketHandshakeException) {
                throw HandshakeException(refused.response.statusCode(), refused.response.statusCode().toString())
            } catch (refused: IOException) {
                throw ActionCableException("actioncable: dialing $url", refused)
            }

        return WebSocketConn(socket, incoming, writeTimeout)
    }
}

/**
 * One connection on the JDK's WebSocket client.
 *
 * The JDK pushes messages at a listener rather than answering a read, so
 * [Incoming] takes them as they land and queues them for whoever is reading.
 */
internal class WebSocketConn(private val socket: WebSocket, private val incoming: Incoming, private val writeTimeout: Duration) :
    Conn,
    StatusCloser {
    override val subprotocol: String get() = socket.subprotocol

    override suspend fun read(): ByteArray = incoming.next()

    override suspend fun write(payload: ByteArray) {
        withTimeout(writeTimeout) { socket.sendText(payload.decodeToString(), true).await() }
    }

    override suspend fun close() {
        closeWithStatus(WebSocket.NORMAL_CLOSURE, "")
    }

    /**
     * The close frame goes out and the socket is dropped right after, whether
     * or not the server answers: waiting on a peer that may already be gone
     * would hold up whoever is hanging up. A socket that has already said
     * goodbye — because the server closed first, or because this ran twice —
     * sends nothing more.
     */
    override suspend fun closeWithStatus(code: Int, reason: String) {
        try {
            socket.sendClose(code, reason.truncatedToCloseReason()).await()
        } catch (ignored: Exception) {
            // The peer is gone, which is what we were telling it about anyway.
        } finally {
            socket.abort()
            incoming.hungUp()
        }
    }

    /**
     * Takes what the JDK delivers and hands it on whole. Text and binary both
     * arrive in parts with the last one flagged, so a fragmented message is
     * reassembled here, and one past the limit is refused as soon as the parts
     * in hand are over it.
     */
    internal class Incoming(private val maxMessageSize: Long) : WebSocket.Listener {
        private val messages = Channel<ByteArray>(Channel.UNLIMITED)
        private val text = StringBuilder()
        private var binary = ByteArray(0)

        @Volatile
        private var ended: Throwable? = null

        /**
         * The next complete message. Anything buffered is handed over before
         * the failure that ended the connection, the way a socket's own reads
         * drain before they start failing.
         */
        suspend fun next(): ByteArray = messages.receiveCatching().getOrNull()
            ?: throw (ended ?: CloseException(NO_STATUS_CODE, ""))

        /** Wakes a read that will never be answered, because nothing is listening any more. */
        fun hungUp() {
            end(CloseException(WebSocket.NORMAL_CLOSURE, ""))
        }

        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            text.append(data)
            if (text.length > maxMessageSize) {
                return tooBig(webSocket, "${text.length} characters")
            }
            if (last) {
                messages.trySend(text.toString().encodeToByteArray())
                text.setLength(0)
            }
            webSocket.request(1)

            return null
        }

        override fun onBinary(webSocket: WebSocket, data: ByteBuffer, last: Boolean): CompletionStage<*>? {
            binary += ByteArray(data.remaining()).also { data.get(it) }
            if (binary.size > maxMessageSize) {
                return tooBig(webSocket, "${binary.size} bytes")
            }
            if (last) {
                messages.trySend(binary)
                binary = ByteArray(0)
            }
            webSocket.request(1)

            return null
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
            end(CloseException(statusCode, reason))

            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            end(error)
        }

        private fun tooBig(webSocket: WebSocket, size: String): CompletionStage<*>? {
            end(MessageTooBigException("actioncable: message exceeds the maximum size: $size against a limit of $maxMessageSize"))
            webSocket.abort()

            return null
        }

        private fun end(failure: Throwable) {
            if (ended == null) {
                ended = failure
            }
            messages.close()
        }
    }
}

/**
 * RFC 6455 §7.4.1's code that stands in for a close frame carrying none. The
 * JDK reports it the same way.
 */
private const val NO_STATUS_CODE = 1005

/** What fits in a close frame after the code: a control frame's payload is at most 125 bytes. */
private const val MAX_CLOSE_REASON_BYTES = 123

private fun String.truncatedToCloseReason(): String {
    var reason = this
    while (reason.encodeToByteArray().size > MAX_CLOSE_REASON_BYTES) {
        reason = reason.dropLast(1)
    }

    return reason
}
