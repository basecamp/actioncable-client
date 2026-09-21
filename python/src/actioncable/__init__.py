"""A client for Rails' Action Cable.

A :class:`Client` owns one WebSocket connection to an Action Cable server and
multiplexes any number of channel subscriptions over it. It keeps the
connection alive the way the official JavaScript client does: the server beats
a ping every three seconds, and a connection that goes quiet for longer than
``stale_after`` is torn down and redialed with backoff. Subscriptions survive
reconnects — they are resubscribed as soon as the server says welcome.

    client = actioncable.Client("wss://example.com/cable")
    await client.connect(timeout=10)

    room = await client.subscribe(actioncable.Identifier("RoomChannel", {"id": 42}))

    async def listen() -> None:
        async for message in room:
            print(message.json()["body"])

    listening = asyncio.create_task(listen())
    await room.perform("speak", {"body": "Hello!"})

Two things are pluggable. A :class:`Transport` carries bytes — the built-in
:class:`WebSocketTransport` speaks RFC 6455 over ``asyncio`` streams, and any
WebSocket package can be dropped in behind the same protocol. A
:class:`Protocol` speaks one Action Cable wire format, negotiated as one
WebSocket subprotocol — :class:`V1JSON` implements ``actioncable-v1-json``, and
a new format is a new protocol rather than a fork of this client.
``protocols=`` offers several, and the server picks the one it knows.
"""

from ._version import VERSION
from .client import Client, HeadersFunc, StopOnError
from .errors import (
    ActionCableError,
    AlreadyConnectedError,
    ClosedError,
    CloseError,
    DisconnectError,
    GaveUpError,
    HandshakeError,
    MessageTooBigError,
    NoProtocolsError,
    NotConnectedError,
    RejectedError,
    UnsubscribedError,
    UnsupportedSubprotocolError,
)
from .headers import Headers
from .identifier import Identifier, Params
from .message import Message
from .protocol import (
    REASON_INVALID_REQUEST,
    REASON_REMOTE,
    REASON_SERVER_RESTART,
    REASON_UNAUTHORIZED,
    SUBPROTOCOL_UNSUPPORTED,
    Command,
    CommandName,
    Incoming,
    Kind,
    Protocol,
)
from .subscription import OnConnected, OnDisconnected, OnRejected, Subscription
from .transport import Conn, DialOptions, StatusCloser, Transport
from .v1_json import SUBPROTOCOL_V1_JSON, V1JSON
from .websocket import WebSocketConn, WebSocketTransport

__all__ = [
    "REASON_INVALID_REQUEST",
    "REASON_REMOTE",
    "REASON_SERVER_RESTART",
    "REASON_UNAUTHORIZED",
    "SUBPROTOCOL_UNSUPPORTED",
    "SUBPROTOCOL_V1_JSON",
    "VERSION",
    "V1JSON",
    "ActionCableError",
    "AlreadyConnectedError",
    "Client",
    "CloseError",
    "ClosedError",
    "Command",
    "CommandName",
    "Conn",
    "DialOptions",
    "DisconnectError",
    "GaveUpError",
    "HandshakeError",
    "Headers",
    "HeadersFunc",
    "Identifier",
    "Incoming",
    "Kind",
    "Message",
    "MessageTooBigError",
    "NoProtocolsError",
    "NotConnectedError",
    "OnConnected",
    "OnDisconnected",
    "OnRejected",
    "Params",
    "Protocol",
    "RejectedError",
    "StatusCloser",
    "StopOnError",
    "Subscription",
    "Transport",
    "UnsubscribedError",
    "UnsupportedSubprotocolError",
    "WebSocketConn",
    "WebSocketTransport",
]
