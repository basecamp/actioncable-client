package com.basecamp.actioncable

/**
 * Translates between Action Cable commands and the bytes on the wire. It is
 * the seam where an Action Cable protocol plugs in.
 *
 * One protocol speaks one subprotocol. A client offers every protocol it was
 * given and speaks the one the server picks, so supporting a new protocol means
 * adding one rather than replacing the list.
 *
 * Implementations must be safe to use from several coroutines at once.
 */
interface Protocol {
    /** The name this protocol negotiates under. */
    val subprotocol: String

    /** Turns a command into one outgoing message. */
    fun encode(command: Command): ByteArray

    /** Turns one incoming message into a frame the client understands. */
    fun decode(payload: ByteArray): Incoming
}

/**
 * The sentinel an Action Cable server names when it speaks none of the
 * subprotocols offered. The client offers it last on every handshake, the way
 * Rails' own clients do, so a server with nothing in common can say so outright
 * instead of leaving the subprotocol blank.
 */
const val SUBPROTOCOL_UNSUPPORTED = "actioncable-unsupported"

/** The verb of a client-to-server command. */
enum class CommandName(val wire: String) {
    SUBSCRIBE("subscribe"),
    UNSUBSCRIBE("unsubscribe"),
    MESSAGE("message"),
    ;

    override fun toString(): String = wire
}

/**
 * A client-to-server message. [data] carries the already encoded action payload
 * and is only set for [CommandName.MESSAGE].
 */
class Command(val name: CommandName, val identifier: String, val data: String = "")

/** The type of a server-to-client frame. */
enum class Kind(val wire: String) {
    WELCOME("welcome"),
    PING("ping"),
    DISCONNECT("disconnect"),
    CONFIRMATION("confirm_subscription"),
    REJECTION("reject_subscription"),
    MESSAGE("message"),
    ;

    override fun toString(): String = wire
}

/**
 * A decoded server-to-client frame. [reason] and [reconnect] are only set on
 * [Kind.DISCONNECT], [message] on [Kind.MESSAGE] and [Kind.PING].
 */
class Incoming(
    val kind: Kind,
    val identifier: String = "",
    val message: Message = Message.EMPTY,
    val reason: String = "",
    val reconnect: Boolean = false,
)

/** The reasons an Action Cable server gives before hanging up. */
object DisconnectReason {
    const val UNAUTHORIZED = "unauthorized"
    const val INVALID_REQUEST = "invalid_request"
    const val SERVER_RESTART = "server_restart"
    const val REMOTE = "remote"
}
