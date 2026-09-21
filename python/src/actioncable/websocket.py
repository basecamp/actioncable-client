"""The built-in transport: an RFC 6455 client on asyncio streams.

Written on the standard library, so the package carries no dependencies. It
handles the upgrade handshake, masks what it sends, answers pings, and
reassembles fragmented messages.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import secrets
import ssl as ssl_module
from dataclasses import dataclass
from email.parser import BytesParser
from typing import NoReturn
from urllib.parse import SplitResult, urlsplit

from ._version import VERSION
from .errors import ActionCableError, CloseError, HandshakeError, MessageTooBigError
from .headers import Headers
from .transport import Conn, DialOptions

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

# RFC 6455 §7.4.1's two codes this side needs by name: the one a close frame
# carries by default, and the one that stands in for a frame carrying none.
CLOSE_NORMAL = 1000
CLOSE_NO_STATUS = 1005

# What fits in a close frame after the code: a control frame's payload is at
# most 125 bytes.
MAX_CLOSE_REASON_BYTES = 123

USER_AGENT = f"actioncable-python/{VERSION}"

# What a socket says on the way out is no news to whoever is hanging up.
_HANGING_UP = (OSError, asyncio.IncompleteReadError, TimeoutError)


class WebSocketTransport:
    """Dials RFC 6455 connections over ``asyncio`` streams.

    ``ssl_context`` configures ``wss://`` connections, ``handshake_timeout``
    bounds the upgrade, ``write_timeout`` bounds a single write, and
    ``max_message_size`` is the largest message accepted, in bytes.
    """

    def __init__(
        self,
        *,
        ssl_context: ssl_module.SSLContext | None = None,
        handshake_timeout: float = 10.0,
        write_timeout: float = 10.0,
        max_message_size: int = 8 << 20,
    ) -> None:
        self._ssl_context = ssl_context
        self._handshake_timeout = handshake_timeout
        self._write_timeout = write_timeout
        self._max_message_size = max_message_size

    async def dial(self, url: str, options: DialOptions) -> Conn:
        endpoint = urlsplit(url)
        host, port, secure = _endpoint_address(endpoint)

        async with asyncio.timeout(self._handshake_timeout):
            reader, writer = await asyncio.open_connection(
                host,
                port,
                ssl=self._tls_context() if secure else None,
                server_hostname=host if secure else None,
            )

            try:
                return await self._upgrade(reader, writer, endpoint, options)
            except BaseException:
                writer.close()
                raise

    def _tls_context(self) -> ssl_module.SSLContext:
        if self._ssl_context is not None:
            return self._ssl_context
        else:
            return ssl_module.create_default_context()

    async def _upgrade(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        endpoint: SplitResult,
        options: DialOptions,
    ) -> WebSocketConn:
        key = base64.b64encode(secrets.token_bytes(16)).decode()

        writer.write(_upgrade_request(endpoint, key, options))
        await writer.drain()

        status_code, status, headers = await _read_response(reader)
        _verify_upgrade(status_code, status, headers, key)

        return WebSocketConn(
            reader,
            writer,
            subprotocol=headers.get("Sec-WebSocket-Protocol", ""),
            write_timeout=self._write_timeout,
            max_message_size=self._max_message_size,
        )


class WebSocketConn:
    """One live RFC 6455 connection."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        *,
        subprotocol: str,
        write_timeout: float,
        max_message_size: int,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._subprotocol = subprotocol
        self._write_timeout = write_timeout
        self._max_message_size = max_message_size
        self._write_lock = asyncio.Lock()
        self._close_sent = False
        self._closed = False

    @property
    def subprotocol(self) -> str:
        return self._subprotocol

    async def read(self) -> bytes:
        message = b""
        fragmented = False

        while True:
            frame = await self._read_frame()

            if frame.opcode in (OP_TEXT, OP_BINARY):
                if fragmented:
                    await self._fail("received a new data frame in the middle of a fragmented message")
                if frame.final:
                    return frame.payload
                message, fragmented = frame.payload, True
            elif frame.opcode == OP_CONTINUATION:
                if not fragmented:
                    await self._fail("received a continuation frame outside a fragmented message")
                if len(message) + len(frame.payload) > self._max_message_size:
                    await self._fail(f"a message past {self._max_message_size} bytes", MessageTooBigError)
                message += frame.payload
                if frame.final:
                    return message
            elif frame.opcode == OP_PING:
                await self._write_frame(OP_PONG, frame.payload)
            elif frame.opcode == OP_PONG:
                pass
            elif frame.opcode == OP_CLOSE:
                # One close frame in reply, then the socket goes: close sees
                # the reply was already sent and won't send a second one.
                with contextlib.suppress(*_HANGING_UP):
                    await self._write_frame(OP_CLOSE, _close_reply(frame.payload))
                await self.close()
                raise _close_error_from(frame.payload)
            else:
                await self._fail(f"received unknown opcode {frame.opcode:#x}")

    async def write(self, payload: bytes) -> None:
        await self._write_frame(OP_TEXT, payload)

    async def close(self) -> None:
        await self.close_with_status(CLOSE_NORMAL, "")

    async def close_with_status(self, code: int, reason: str) -> None:
        """Hang up with a code and reason of the caller's choosing.

        The close frame is written with a short deadline and the socket closed
        right after, whether or not the server answers: waiting on a peer that
        may already be gone would hold up whoever is hanging up.
        """
        if self._closed:
            return
        self._closed = True

        async with self._write_lock:
            if not self._close_sent:
                with contextlib.suppress(*_HANGING_UP):
                    async with asyncio.timeout(1.0):
                        await self._write_masked(OP_CLOSE, _close_frame(code, reason))

        self._writer.close()
        with contextlib.suppress(*_HANGING_UP):
            await self._writer.wait_closed()

    async def _read_frame(self) -> _Frame:
        header = await self._reader.readexactly(2)

        final = bool(header[0] & 0x80)
        opcode = header[0] & 0x0F
        if header[0] & 0x70:
            await self._fail("received a frame with reserved bits set")

        # RFC 6455 §5.1: a server must not mask what it sends, and a client
        # that receives a masked frame must fail the connection.
        if header[1] & 0x80:
            await self._fail("received a masked frame from the server")

        length = header[1] & 0x7F
        if length == 126:
            length = int.from_bytes(await self._reader.readexactly(2), "big")
        elif length == 127:
            length = int.from_bytes(await self._reader.readexactly(8), "big") & 0x7FFFFFFFFFFFFFFF

        if opcode >= OP_CLOSE and (not final or length > 125):
            await self._fail("received a fragmented or oversized control frame")
        if length > self._max_message_size:
            await self._fail(
                f"a {length} byte frame against a limit of {self._max_message_size}",
                MessageTooBigError,
            )

        return _Frame(final=final, opcode=opcode, payload=await self._reader.readexactly(length))

    async def _write_frame(self, opcode: int, payload: bytes) -> None:
        async with self._write_lock, asyncio.timeout(self._write_timeout):
            await self._write_masked(opcode, payload)

    async def _write_masked(self, opcode: int, payload: bytes) -> None:
        if opcode == OP_CLOSE:
            self._close_sent = True

        mask = secrets.token_bytes(4)

        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length <= 125:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.append(0x80 | 126)
            header += length.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += length.to_bytes(8, "big")
        header += mask

        self._writer.write(bytes(header) + apply_mask(mask, payload))
        await self._writer.drain()

    async def _fail(self, reason: str, kind: type[ActionCableError] = ActionCableError) -> NoReturn:
        """Fail the connection: a frame we can't trust means the peer isn't
        speaking the protocol, and reading on would be guesswork."""
        await self.close()

        raise kind(reason)


@dataclass(frozen=True)
class _Frame:
    final: bool
    opcode: int
    payload: bytes


def apply_mask(mask: bytes, payload: bytes) -> bytes:
    """XOR a payload with a four-byte mask.

    Only what this client sends is masked, and what it sends is Action Cable
    commands, so a byte at a time is fast enough here.
    """
    return bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def accept_key(key: str) -> str:
    """The Sec-WebSocket-Accept a server owes for a key.

    SHA-1 is what RFC 6455 §4.2.2 names; it proves the peer read the key, and
    guards nothing.
    """
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()  # noqa: S324

    return base64.b64encode(digest).decode()


def _endpoint_address(endpoint: SplitResult) -> tuple[str, int, bool]:
    if endpoint.scheme.lower() in ("ws", "http"):
        secure = False
    elif endpoint.scheme.lower() in ("wss", "https"):
        secure = True
    else:
        raise ActionCableError(f"unsupported scheme {endpoint.scheme!r}")

    if not endpoint.hostname:
        raise ActionCableError(f"the cable URL names no host: {endpoint.geturl()!r}")

    if endpoint.port is not None:
        return endpoint.hostname, endpoint.port, secure
    elif secure:
        return endpoint.hostname, 443, secure
    else:
        return endpoint.hostname, 80, secure


def _upgrade_request(endpoint: SplitResult, key: str, options: DialOptions) -> bytes:
    target = endpoint.path or "/"
    if endpoint.query:
        target += "?" + endpoint.query

    headers = Headers(options.headers)
    headers.pop("Sec-WebSocket-Extensions", None)
    headers.setdefault("User-Agent", USER_AGENT)
    headers["Host"] = endpoint.netloc
    headers["Upgrade"] = "websocket"
    headers["Connection"] = "Upgrade"
    headers["Sec-WebSocket-Key"] = key
    headers["Sec-WebSocket-Version"] = "13"
    if options.subprotocols:
        headers["Sec-WebSocket-Protocol"] = ", ".join(options.subprotocols)
    else:
        headers.pop("Sec-WebSocket-Protocol", None)

    lines = [f"GET {target} HTTP/1.1"]
    lines += [f"{name}: {_one_line(value)}" for name, value in headers.items()]

    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1", errors="replace")


def _one_line(value: str) -> str:
    """Keep a header value on its own line.

    A value carrying CR or LF would otherwise end the header and start another
    of the caller's choosing, which is how a token read from somewhere else
    becomes a request nobody wrote.
    """
    return value.replace("\r", " ").replace("\n", " ")


async def _read_response(reader: asyncio.StreamReader) -> tuple[int, str, Headers]:
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError) as error:
        raise ActionCableError(f"reading upgrade response: {error}") from error

    status_line, _, rest = head.partition(b"\r\n")
    parts = status_line.decode("latin-1").split(" ", 2)
    if len(parts) < 2 or not parts[1].isdigit():
        raise ActionCableError(f"reading upgrade response: bad status line {status_line!r}")

    parsed = BytesParser().parsebytes(rest)

    return int(parts[1]), " ".join(parts[1:]), Headers(dict(parsed.items()))


def _verify_upgrade(status_code: int, status: str, headers: Headers, key: str) -> None:
    if status_code != 101:
        raise HandshakeError(status_code, status)

    upgrade = headers.get("Upgrade", "")
    if upgrade.lower() != "websocket":
        raise ActionCableError(f"server did not upgrade to websocket (Upgrade: {upgrade!r})")

    connection = headers.get("Connection", "")
    if not _header_contains(connection, "upgrade"):
        raise ActionCableError(f"server did not upgrade the connection (Connection: {connection!r})")

    accepted = headers.get("Sec-WebSocket-Accept", "")
    if accepted != accept_key(key):
        raise ActionCableError(f"server sent a bad Sec-WebSocket-Accept: {accepted!r}")

    extensions = headers.get("Sec-WebSocket-Extensions", "")
    if extensions:
        raise ActionCableError(f"server negotiated unrequested extensions: {extensions!r}")


def _header_contains(header: str, token: str) -> bool:
    return any(value.strip().lower() == token for value in header.split(","))


def _close_reply(received: bytes) -> bytes:
    """The close frame sent back for one the server sent.

    Its own code is echoed when we're allowed to send it ourselves — normal,
    going away, or an application's own — and normal closure otherwise.
    """
    code = CLOSE_NORMAL

    if len(received) >= 2:
        echoed = int.from_bytes(received[:2], "big")
        if echoed >= 3000 or echoed in (CLOSE_NORMAL, 1001):
            code = echoed

    return _close_frame(code, "")


def _close_frame(code: int, reason: str) -> bytes:
    """A close frame's payload: the code, then as much of the reason as a
    control frame has room for."""
    return code.to_bytes(2, "big") + reason.encode()[:MAX_CLOSE_REASON_BYTES]


def _close_error_from(payload: bytes) -> CloseError:
    if len(payload) < 2:
        return CloseError(CLOSE_NO_STATUS)
    else:
        return CloseError(int.from_bytes(payload[:2], "big"), payload[2:].decode(errors="replace"))
