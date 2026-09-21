package com.basecamp.actioncable

/**
 * Everything this client throws on its own. Go's package answers with sentinel
 * error values a caller matches with `errors.Is`; here each one is a type a
 * caller matches with `is`, and what Go wraps is what Kotlin puts in [cause].
 */
open class ActionCableException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Thrown by a client that has been closed, or that stopped because the server
 * told it not to reconnect.
 */
class ClosedException : ActionCableException("actioncable: client closed")

/**
 * Thrown when a command can't be sent because the connection is down.
 * Subscriptions recover on their own; a perform or send that hits this is lost
 * and must be retried.
 */
class NotConnectedException : ActionCableException("actioncable: not connected")

/** Thrown by subscribe when the channel's `subscribed` method rejected it. */
class RejectedException(val identifier: String) : ActionCableException("actioncable: subscription rejected: $identifier")

/**
 * Thrown when the server negotiated a subprotocol no protocol adapter speaks.
 * Reconnecting won't fix that, so the client stops.
 */
class UnsupportedSubprotocolException(message: String) : ActionCableException(message)

/** Thrown by connect on a client that is already running. */
class AlreadyConnectedException : ActionCableException("actioncable: already connected")

/** Thrown when there is nothing to offer the server, which means no protocols were given. */
class NoProtocolsException : ActionCableException("actioncable: no protocols to offer")

/**
 * Thrown by a client that stopped because it failed as many attempts in a row
 * as `maxAttempts` allows. The last attempt's failure is the [cause].
 */
class GaveUpException(cause: Throwable?) : ActionCableException("actioncable: gave up connecting", cause)

/**
 * Reported by a client whose connect was cancelled before the welcome arrived —
 * the coroutine was cancelled, or a `withTimeout` around it ran out. The
 * failure the client was waiting out, if there was one, is the [cause], so a
 * deadline that ran out on bad credentials says so.
 */
class ConnectCancelledException(cause: Throwable?) : ActionCableException("actioncable: cancelled before the welcome", cause)

/** Reported by a subscription after it was unsubscribed. */
class UnsubscribedException : ActionCableException("actioncable: unsubscribed")

/**
 * Thrown by a connection's read when the server sent a message larger than the
 * transport allows.
 */
class MessageTooBigException(message: String) : ActionCableException(message)

/**
 * Reported when a connection went longer than `staleAfter` without a frame. An
 * Action Cable server beats a ping every three seconds, so silence that long is
 * a connection nobody is on the other end of.
 */
class StaleConnectionException(message: String) : ActionCableException(message)

/** Reports that the server sent a disconnect frame. */
class DisconnectException(val reason: String, val reconnect: Boolean) : ActionCableException("actioncable: server disconnected: $reason")

/**
 * Reports that the server answered the upgrade request with something other
 * than 101 Switching Protocols. [statusCode] is what it answered instead, so a
 * caller can tell a redirect from a refusal; [status] is the status line where
 * the transport can see one.
 */
class HandshakeException(val statusCode: Int, val status: String) :
    ActionCableException("actioncable: server refused the upgrade with $status")

/**
 * Reports that the server closed the connection with a close frame. [code] is
 * the status code the frame carried, 1005 when it carried none, and [reason] is
 * the text after it, if any.
 */
class CloseException(val code: Int, val reason: String) :
    ActionCableException(
        if (reason.isEmpty()) {
            "actioncable: server closed the connection: $code"
        } else {
            "actioncable: server closed the connection: $code $reason"
        },
    )
