package com.basecamp.actioncable

/**
 * Dials the network connection a client talks over. It is the seam where a
 * network handler plugs in: the built-in transport speaks WebSocket on the
 * platform's own client, and wrapping OkHttp, Ktor, or an in-memory pipe for
 * tests means implementing these two interfaces and nothing else.
 */
interface Transport {
    suspend fun dial(url: String, options: DialOptions): Conn
}

/**
 * What the client needs the transport to negotiate: the subprotocols its
 * protocol adapters speak, and the headers that authenticate the request.
 */
class DialOptions(val subprotocols: List<String> = emptyList(), val headers: Headers = Headers.EMPTY)

/**
 * One live connection.
 *
 * [read] and [write] are each called from one coroutine at a time, but [close]
 * may be called while either is suspended and has to wake it.
 */
interface Conn {
    /** What the server negotiated, empty when it named none. */
    val subprotocol: String

    /** The next complete message. It throws once the connection is unusable. */
    suspend fun read(): ByteArray

    /** Sends one text message. */
    suspend fun write(payload: ByteArray)

    suspend fun close()
}

/**
 * A [Conn] that can say why it is hanging up. [Conn.close] sends a close frame
 * with 1000 Normal Closure; [closeWithStatus] sends one with the code and
 * reason given, for a caller with something to tell the server. The built-in
 * transport's connections implement it.
 */
interface StatusCloser {
    suspend fun closeWithStatus(code: Int, reason: String)
}

/** The transport a client uses when it was given none: the platform's own. */
expect fun defaultTransport(): Transport
