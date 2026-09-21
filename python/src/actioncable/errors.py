"""Everything this package raises.

Go's client reports these as sentinel error values compared with ``errors.Is``.
Python's equivalent is a class per failure under one base, so ``except`` does
what ``errors.Is`` does there, and the chain a ``raise ... from ...`` builds
does what ``%w`` does.
"""

from __future__ import annotations


class ActionCableError(Exception):
    """Base class for every error this package raises."""


class ClosedError(ActionCableError):
    """The client was closed, or stopped because the server told it not to come back."""

    def __init__(self, message: str = "client closed") -> None:
        super().__init__(message)


class NotConnectedError(ActionCableError):
    """A command could not be sent because the connection is down.

    Subscriptions recover on their own; a perform or send that hits this is
    lost and must be retried.
    """

    def __init__(self, message: str = "not connected") -> None:
        super().__init__(message)


class RejectedError(ActionCableError):
    """The channel's ``subscribed`` method turned the subscription down."""

    def __init__(self, identifier: str = "") -> None:
        super().__init__(f"subscription rejected: {identifier}" if identifier else "subscription rejected")
        self.identifier = identifier


class UnsupportedSubprotocolError(ActionCableError):
    """The server negotiated a subprotocol no protocol here speaks.

    Dialing again won't change it, so the client stops.
    """


class AlreadyConnectedError(ActionCableError):
    """``connect`` was called on a client that is already running."""

    def __init__(self, message: str = "already connected") -> None:
        super().__init__(message)


class NoProtocolsError(ActionCableError):
    """There is nothing to offer the server, which means ``protocols=[]``."""

    def __init__(self, message: str = "no protocols to offer") -> None:
        super().__init__(message)


class GaveUpError(ActionCableError):
    """As many attempts failed in a row as ``max_attempts`` allows.

    The last attempt's error is the cause, and is named in the message.
    """

    def __init__(self, message: str = "gave up connecting") -> None:
        super().__init__(message)


class UnsubscribedError(ActionCableError):
    """A subscription's ``error`` after ``unsubscribe``."""

    def __init__(self, message: str = "unsubscribed") -> None:
        super().__init__(message)


class MessageTooBigError(ActionCableError):
    """The server sent a message larger than the transport allows.

    The message is refused as soon as its length is known, before any of it is
    read in, and the connection is failed.
    """


class DisconnectError(ActionCableError):
    """The server sent a disconnect frame."""

    def __init__(self, reason: str, reconnect: bool) -> None:
        super().__init__(f"server disconnected: {reason}")
        self.reason = reason
        self.reconnect = reconnect


class HandshakeError(ActionCableError):
    """The server answered the upgrade with something other than 101.

    ``status_code`` is what it answered instead, so a caller can tell a
    redirect from a refusal; ``status`` is the whole status line as the server
    wrote it.
    """

    def __init__(self, status_code: int, status: str) -> None:
        super().__init__(f"server refused the upgrade with {status}")
        self.status_code = status_code
        self.status = status


class CloseError(ActionCableError):
    """The server closed the connection with a close frame.

    ``code`` is the status the frame carried, 1005 when it carried none, and
    ``reason`` is the text after it, if any.
    """

    def __init__(self, code: int, reason: str = "") -> None:
        if reason:
            super().__init__(f"server closed the connection: {code} {reason}")
        else:
            super().__init__(f"server closed the connection: {code}")
        self.code = code
        self.reason = reason
