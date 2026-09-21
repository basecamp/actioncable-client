"""The seam where a network handler plugs in."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

from .headers import Headers


@dataclass
class DialOptions:
    """What the client needs the transport to negotiate: the subprotocols its
    protocols speak, and the headers that authenticate the request — a cookie
    or a token, since an Action Cable server authorizes the upgrade itself."""

    subprotocols: list[str] = field(default_factory=list)
    headers: Headers = field(default_factory=Headers)


@runtime_checkable
class Conn(Protocol):
    """One live connection.

    :meth:`read` and :meth:`write` are each awaited from a single task at a
    time, but :meth:`close` may be called while either is in flight and must
    interrupt it. Cancelling the task awaiting a read or a write is asyncio's
    business and leaves the connection unusable, as tripping a deadline does
    in Go.
    """

    @property
    def subprotocol(self) -> str:
        """What the server negotiated, empty if it named none."""
        ...

    async def read(self) -> bytes:
        """The next complete message. Raises once the connection is unusable."""
        ...

    async def write(self, payload: bytes) -> None:
        """Send one text message."""
        ...

    async def close(self) -> None: ...


@runtime_checkable
class Transport(Protocol):
    """Dials the network connection a client talks over.

    The built-in :class:`~actioncable.websocket.WebSocketTransport` speaks
    RFC 6455 on ``asyncio`` streams; wrapping ``websockets``, ``aiohttp`` or an
    in-memory pipe for tests means implementing these two protocols and
    nothing else.
    """

    async def dial(self, url: str, options: DialOptions) -> Conn:
        """Open one connection."""
        ...


@runtime_checkable
class StatusCloser(Protocol):
    """A :class:`Conn` that can say why it is hanging up.

    ``close`` sends a close frame with 1000 Normal Closure;
    :meth:`close_with_status` sends one with the code and reason given, for a
    caller with something to tell the server. The built-in transport's
    connections implement it.
    """

    async def close_with_status(self, code: int, reason: str) -> None: ...
