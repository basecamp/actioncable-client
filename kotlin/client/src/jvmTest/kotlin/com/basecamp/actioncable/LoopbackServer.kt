package com.basecamp.actioncable

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.fail

const val OP_CONTINUATION: Int = 0x0
const val OP_TEXT: Int = 0x1
const val OP_BINARY: Int = 0x2
const val OP_CLOSE: Int = 0x8
const val OP_PING: Int = 0x9
const val OP_PONG: Int = 0xa

private const val WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
private val WAIT_SECONDS = 5L

/**
 * Speaks just enough of the server side of RFC 6455 to exercise the transport:
 * it completes the handshake by hand and then hands the raw socket over, so
 * every byte the client sends and every byte it is sent is the test's to
 * inspect.
 *
 * @param badAccept answers with a Sec-WebSocket-Accept the client should refuse.
 * @param refuseWith an HTTP response written instead of the upgrade, for the
 *   handshake failures — a 404 or a redirect.
 */
class LoopbackServer(private val badAccept: Boolean = false, private val refuseWith: String? = null) : AutoCloseable {
    private val serverSocket = ServerSocket(0, 16, InetAddress.getLoopbackAddress())
    private val accepted = LinkedBlockingQueue<Peer>()

    init {
        thread(isDaemon = true, name = "loopback-cable") { serve() }
    }

    val url: String get() = "ws://127.0.0.1:${serverSocket.localPort}/cable"

    suspend fun accept(): Peer = withContext(Dispatchers.IO) { accepted.poll(WAIT_SECONDS, TimeUnit.SECONDS) }
        ?: fail("no client connected")

    override fun close() {
        serverSocket.close()
    }

    private fun serve() {
        while (!serverSocket.isClosed) {
            val socket =
                try {
                    serverSocket.accept()
                } catch (closed: SocketException) {
                    return
                }

            socket.tcpNoDelay = true
            val input = socket.getInputStream().buffered()
            val request = Request.read(input)

            if (refuseWith != null) {
                socket.getOutputStream().write(refuseWith.toByteArray())
                socket.getOutputStream().flush()
                socket.close()
                continue
            }

            socket.getOutputStream().write(upgradeResponse(request).toByteArray())
            socket.getOutputStream().flush()
            accepted.put(Peer(socket, input, request))
        }
    }

    private fun upgradeResponse(request: Request): String {
        val accept =
            if (badAccept) {
                "obviously-wrong"
            } else {
                acceptKey(request.headers["sec-websocket-key"]?.first().orEmpty())
            }

        return buildString {
            append("HTTP/1.1 101 Switching Protocols\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Accept: $accept\r\n")
            request.headers["sec-websocket-protocol"]?.first()?.let {
                append("Sec-WebSocket-Protocol: ${it.split(",").first().trim()}\r\n")
            }
            append("\r\n")
        }
    }

    private fun acceptKey(key: String): String =
        Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + WEBSOCKET_GUID).toByteArray()))
}

/** The upgrade request as it came off the wire, before anything interpreted it. */
class Request(val method: String, val path: String, val headers: Map<String, List<String>>) {
    companion object {
        fun read(input: InputStream): Request {
            val requestLine = readLine(input).split(" ")
            val headers = mutableMapOf<String, MutableList<String>>()

            while (true) {
                val line = readLine(input)
                if (line.isEmpty()) {
                    break
                }
                val name = line.substringBefore(":").trim().lowercase()
                headers.getOrPut(name) { mutableListOf() }.add(line.substringAfter(":").trim())
            }

            return Request(requestLine[0], requestLine.getOrElse(1) { "" }, headers)
        }

        private fun readLine(input: InputStream): String {
            val line = StringBuilder()
            while (true) {
                when (val byte = input.read()) {
                    -1 -> throw EOFException("the request ended mid-line")
                    '\n'.code -> return line.removeSuffix("\r").toString()
                    else -> line.append(byte.toChar())
                }
            }
        }
    }

    /** The first value for [name], or null. Header names are matched without regard to case. */
    fun header(name: String): String? = headers[name.lowercase()]?.firstOrNull()
}

/** One frame off the wire. */
class Frame(val final: Boolean, val opcode: Int, val payload: ByteArray) {
    val text: String get() = payload.decodeToString()
}

/** The server's end of one connection, once the handshake is done. */
class Peer(private val socket: Socket, private val input: InputStream, val request: Request) {
    /**
     * The next whole text message the client sent. A long one goes out in
     * several frames — the JDK fragments what it sends at its own buffer size —
     * so the pieces are put back together here, and the control frames that can
     * arrive between them are passed over.
     */
    suspend fun read(): String {
        var message = ByteArray(0)

        while (true) {
            val frame = readFrame()
            when (frame.opcode) {
                OP_PING, OP_PONG -> Unit

                OP_TEXT, OP_CONTINUATION -> {
                    message += frame.payload
                    if (frame.final) {
                        return message.decodeToString()
                    }
                }

                else -> fail("expected a text frame, got opcode ${frame.opcode}")
            }
        }
    }

    suspend fun readFrame(): Frame = withContext(Dispatchers.IO) { tryReadFrame() ?: fail("the client sent no frame") }

    suspend fun write(opcode: Int, payload: ByteArray) {
        writeFragment(opcode, payload, true)
    }

    suspend fun write(opcode: Int, payload: String) {
        writeFragment(opcode, payload.toByteArray(), true)
    }

    suspend fun writeFragment(opcode: Int, payload: ByteArray, final: Boolean) = withContext(Dispatchers.IO) {
        val header = mutableListOf<Byte>()
        header.add((if (final) opcode or 0x80 else opcode).toByte())
        when {
            payload.size <= 125 -> header.add(payload.size.toByte())

            payload.size <= 0xffff -> {
                header.add(126)
                header.add((payload.size shr 8).toByte())
                header.add(payload.size.toByte())
            }

            else -> {
                header.add(127)
                repeat(8) { header.add((payload.size.toLong() shr (56 - it * 8)).toByte()) }
            }
        }

        writeBytes(header.toByteArray() + payload)
    }

    /** Sends a frame the way only a client is allowed to: masked. */
    suspend fun writeMasked(opcode: Int, payload: ByteArray) = withContext(Dispatchers.IO) {
        val mask = byteArrayOf(1, 2, 3, 4)
        val masked = payload.copyOf().also { applyMask(mask, it) }
        val header = byteArrayOf((0x80 or opcode).toByte(), (0x80 or payload.size).toByte()) + mask

        writeBytes(header + masked)
    }

    /** How many close frames the client sends before it goes away. */
    suspend fun closeFrames(): Int = withContext(Dispatchers.IO) {
        var closes = 0
        var frame = tryReadFrame()
        while (frame != null) {
            if (frame.opcode == OP_CLOSE) {
                closes++
            }
            frame = tryReadFrame()
        }

        closes
    }

    private fun writeBytes(bytes: ByteArray) {
        socket.soTimeout = (WAIT_SECONDS * 1000).toInt()
        try {
            socket.getOutputStream().write(bytes)
            socket.getOutputStream().flush()
        } catch (gone: IOException) {
            // The client hung up mid-write, which some of these tests are about.
        }
    }

    private fun tryReadFrame(): Frame? {
        socket.soTimeout = (WAIT_SECONDS * 1000).toInt()

        val header = readFully(2) ?: return null
        val final = header[0].toInt() and 0x80 != 0
        val opcode = header[0].toInt() and 0x0f
        if (header[1].toInt() and 0x80 == 0) {
            fail("client sent an unmasked frame")
        }

        var length = (header[1].toInt() and 0x7f).toLong()
        if (length == 126L) {
            val extended = readFully(2) ?: return null
            length = ((extended[0].toInt() and 0xff) shl 8 or (extended[1].toInt() and 0xff)).toLong()
        } else if (length == 127L) {
            val extended = readFully(8) ?: return null
            length = extended.fold(0L) { total, byte -> total shl 8 or (byte.toLong() and 0xff) }
        }

        val mask = readFully(4) ?: return null
        val payload = readFully(length.toInt()) ?: return null
        applyMask(mask, payload)

        return Frame(final, opcode, payload)
    }

    private fun readFully(count: Int): ByteArray? {
        val bytes = ByteArray(count)
        var read = 0
        while (read < count) {
            val got =
                try {
                    input.read(bytes, read, count - read)
                } catch (gone: IOException) {
                    return null
                }
            if (got < 0) {
                return null
            }
            read += got
        }

        return bytes
    }
}

fun applyMask(mask: ByteArray, payload: ByteArray) {
    payload.indices.forEach { payload[it] = (payload[it].toInt() xor mask[it % 4].toInt()).toByte() }
}
