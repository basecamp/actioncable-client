"""The seam where an Action Cable wire format plugs in."""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from typing import Protocol as Interface
from typing import runtime_checkable

from .message import Message

SUBPROTOCOL_UNSUPPORTED = "actioncable-unsupported"
"""The sentinel an Action Cable server names when it speaks none of the
subprotocols offered. The client offers it last on every handshake, the way
Rails' own clients do, so a server with nothing in common can say so outright
instead of leaving the subprotocol blank."""

REASON_UNAUTHORIZED = "unauthorized"
REASON_INVALID_REQUEST = "invalid_request"
REASON_SERVER_RESTART = "server_restart"
REASON_REMOTE = "remote"


class CommandName(enum.StrEnum):
    """The verb of a client-to-server command."""

    SUBSCRIBE = "subscribe"
    UNSUBSCRIBE = "unsubscribe"
    MESSAGE = "message"


@dataclass(frozen=True)
class Command:
    """A client-to-server message.

    ``data`` carries the already encoded action payload and is only set for
    :attr:`CommandName.MESSAGE`.
    """

    name: CommandName
    identifier: str
    data: str = ""


class Kind(enum.Enum):
    """The type of a server-to-client frame."""

    WELCOME = "welcome"
    PING = "ping"
    DISCONNECT = "disconnect"
    CONFIRMATION = "confirm_subscription"
    REJECTION = "reject_subscription"
    MESSAGE = "message"


@dataclass(frozen=True)
class Incoming:
    """A decoded server-to-client frame.

    ``reason`` and ``reconnect`` are only set on :attr:`Kind.DISCONNECT`,
    ``message`` on :attr:`Kind.MESSAGE` and :attr:`Kind.PING`.
    """

    kind: Kind
    identifier: str = ""
    message: Message = field(default_factory=lambda: Message(""))
    reason: str = ""
    reconnect: bool = False


@runtime_checkable
class Protocol(Interface):
    """Translates between Action Cable commands and the bytes on the wire.

    One protocol speaks one subprotocol. A client offers every protocol it was
    given and speaks the one the server picks, so supporting a new format means
    adding a protocol rather than replacing the list.
    """

    @property
    def subprotocol(self) -> str:
        """The name this protocol negotiates under."""
        ...

    def encode(self, command: Command) -> bytes:
        """Turn a command into one outgoing message."""
        ...

    def decode(self, payload: bytes) -> Incoming:
        """Turn one incoming message into a frame the client understands."""
        ...
