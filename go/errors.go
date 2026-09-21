package actioncable

import (
	"errors"
	"fmt"
)

var (
	// ErrClosed is returned by a client that has been closed, or that stopped
	// because the server told it not to reconnect.
	ErrClosed = errors.New("actioncable: client closed")

	// ErrNotConnected is returned when a command can't be sent because the
	// connection is down. Subscriptions recover on their own; a Perform or Send
	// that hits this is lost and must be retried.
	ErrNotConnected = errors.New("actioncable: not connected")

	// ErrRejected is returned by Subscribe when the channel's subscribed method
	// rejected the subscription.
	ErrRejected = errors.New("actioncable: subscription rejected")

	// ErrUnsupportedSubprotocol is returned when the server negotiated a
	// subprotocol the protocol adapter doesn't speak. Reconnecting won't fix
	// that, so the client stops.
	ErrUnsupportedSubprotocol = errors.New("actioncable: unsupported subprotocol")

	// ErrAlreadyConnected is returned by Connect on a client that is already
	// running.
	ErrAlreadyConnected = errors.New("actioncable: already connected")

	// ErrNoProtocols is returned when there is nothing to offer the server,
	// which means WithProtocols was called without any protocols.
	ErrNoProtocols = errors.New("actioncable: no protocols to offer")

	// ErrGaveUp is returned by a client that stopped because it failed as many
	// attempts in a row as WithMaxAttempts allows. It wraps the last attempt's
	// error.
	ErrGaveUp = errors.New("actioncable: gave up connecting")

	// ErrUnsubscribed is reported by a subscription's Err after Unsubscribe.
	ErrUnsubscribed = errors.New("actioncable: unsubscribed")

	// ErrMessageTooBig is returned by a Conn's Read when the server sent a
	// message larger than the transport allows. The message is refused as soon
	// as its length is known, before any of it is read in, and the connection
	// is failed.
	ErrMessageTooBig = errors.New("actioncable: message exceeds the maximum size")
)

// A DisconnectError reports that the server sent a disconnect frame.
type DisconnectError struct {
	Reason    string
	Reconnect bool
}

func (e *DisconnectError) Error() string {
	return "actioncable: server disconnected: " + e.Reason
}

// A HandshakeError reports that the server answered the upgrade request with
// something other than 101 Switching Protocols. StatusCode is what it answered
// instead, so a caller can tell a redirect from a refusal; Status is the whole
// status line as the server wrote it.
type HandshakeError struct {
	StatusCode int
	Status     string
}

func (e *HandshakeError) Error() string {
	return "actioncable: server refused the upgrade with " + e.Status
}

// A CloseError reports that the server closed the connection with a close
// frame. Code is the status code the frame carried, 1005 when it carried none,
// and Reason is the text after it, if any.
type CloseError struct {
	Code   int
	Reason string
}

func (e *CloseError) Error() string {
	if e.Reason == "" {
		return fmt.Sprintf("actioncable: server closed the connection: %d", e.Code)
	} else {
		return fmt.Sprintf("actioncable: server closed the connection: %d %s", e.Code, e.Reason)
	}
}
