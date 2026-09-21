from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from dataclasses import dataclass, field

import pytest
from conftest import ROOM_IDENTIFIER, receive, room, start

from actioncable import (
    SUBPROTOCOL_V1_JSON,
    ActionCableError,
    Client,
    CloseError,
    Conn,
    DialOptions,
    HandshakeError,
    Headers,
    MessageTooBigError,
    StatusCloser,
    WebSocketTransport,
)
from actioncable.testing import WAIT
from actioncable.websocket import (
    OP_CLOSE,
    OP_CONTINUATION,
    OP_PING,
    OP_PONG,
    OP_TEXT,
    accept_key,
    apply_mask,
)


async def test_web_socket_transport_negotiates_the_subprotocol(server: TestServer) -> None:
    conn = await dial(server, DialOptions(subprotocols=[SUBPROTOCOL_V1_JSON]))

    assert conn.subprotocol == SUBPROTOCOL_V1_JSON
    offered = (await server.accept()).headers["Sec-WebSocket-Protocol"]
    assert offered == SUBPROTOCOL_V1_JSON, "expected the client to offer the subprotocol"


async def test_web_socket_transport_sends_headers(server: TestServer) -> None:
    await dial(
        server,
        DialOptions(
            subprotocols=[SUBPROTOCOL_V1_JSON],
            headers=Headers({"Cookie": "session=secret", "Origin": "https://example.com"}),
        ),
    )

    peer = await server.accept()
    assert peer.headers["Cookie"] == "session=secret"
    assert peer.headers["Origin"] == "https://example.com"
    assert peer.headers["User-Agent"].startswith("actioncable-python/")
    assert peer.target == "/cable"


async def test_web_socket_transport_sends_the_callers_user_agent(server: TestServer) -> None:
    await dial(server, DialOptions(headers=Headers({"User-Agent": "custom-agent"})))

    assert (await server.accept()).headers["User-Agent"] == "custom-agent"


async def test_web_socket_transport_neutralizes_header_injection(server: TestServer) -> None:
    await dial(server, DialOptions(headers=Headers({"Authorization": "Bearer token\r\nX-Injected: gotcha"})))

    peer = await server.accept()
    assert peer.headers.get("X-Injected", "") == "", "expected the newlines to be neutralized"
    assert peer.headers["Authorization"].startswith("Bearer token"), "expected the authorization header to survive"


async def test_web_socket_transport_round_trips_messages(server: TestServer) -> None:
    conn = await dial(server, DialOptions(subprotocols=[SUBPROTOCOL_V1_JSON]))
    peer = await server.accept()

    await conn.write(b'{"command":"subscribe"}')
    assert await peer.read() == '{"command":"subscribe"}'

    await peer.write(OP_TEXT, b'{"type":"welcome"}')
    assert await read(conn) == b'{"type":"welcome"}'


async def test_web_socket_transport_answers_pings(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    await peer.write(OP_PING, b"beat")
    await peer.write(OP_TEXT, b"after the ping")

    assert await read(conn) == b"after the ping"

    frame = await peer.read_frame()
    assert frame.opcode == OP_PONG, "expected a pong"
    assert frame.payload == b"beat", "expected the pong to carry the ping payload"


async def test_web_socket_transport_reassembles_fragments(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    await peer.write_fragment(OP_TEXT, b"one ", final=False)
    await peer.write_fragment(OP_PING, b"interleaved", final=True)
    await peer.write_fragment(OP_CONTINUATION, b"message", final=True)

    assert await read(conn) == b"one message"


async def test_web_socket_transport_reads_large_messages(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    long = b"cable" * 30_000
    await peer.write(OP_TEXT, long)
    assert await read(conn) == long

    await conn.write(long)
    assert await peer.read() == long.decode()


async def test_web_socket_transport_refuses_oversized_messages(server: TestServer) -> None:
    conn = await dial(server, DialOptions(), transport=WebSocketTransport(max_message_size=8))

    await (await server.accept()).write(OP_TEXT, b"far too long for eight bytes")

    with pytest.raises(MessageTooBigError):
        await read(conn)


async def test_web_socket_transport_refuses_oversized_fragmented_messages(server: TestServer) -> None:
    conn = await dial(server, DialOptions(), transport=WebSocketTransport(max_message_size=8))

    peer = await server.accept()
    await peer.write_fragment(OP_TEXT, b"five ", final=False)
    await peer.write_fragment(OP_CONTINUATION, b"more", final=True)

    with pytest.raises(MessageTooBigError):
        await read(conn)


async def test_web_socket_transport_reports_server_close(server: TestServer) -> None:
    conn = await dial(server, DialOptions())

    await (await server.accept()).write(OP_CLOSE, (4401).to_bytes(2, "big") + b"unauthorized")

    with pytest.raises(CloseError) as raised:
        await read(conn)
    assert raised.value.code == 4401
    assert raised.value.reason == "unauthorized"


async def test_web_socket_transport_reports_a_server_close_without_a_status(server: TestServer) -> None:
    conn = await dial(server, DialOptions())

    await (await server.accept()).write(OP_CLOSE, b"")

    with pytest.raises(CloseError) as raised:
        await read(conn)
    assert raised.value.code == 1005
    assert raised.value.reason == ""


async def test_web_socket_transport_closes_with_a_status(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    assert isinstance(conn, StatusCloser), "the built-in connection should implement StatusCloser"
    await conn.close_with_status(4000, "done here")

    frame = await peer.read_frame()
    assert frame.opcode == OP_CLOSE
    assert int.from_bytes(frame.payload[:2], "big") == 4000
    assert frame.payload[2:] == b"done here"


async def test_web_socket_transport_truncates_a_close_reason_to_fit_the_frame(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    assert isinstance(conn, StatusCloser)
    await conn.close_with_status(4000, "r" * 200)

    frame = await peer.read_frame()
    assert frame.opcode == OP_CLOSE
    assert len(frame.payload) == 125, "a control frame's payload is at most 125 bytes"


async def test_web_socket_transport_refuses_a_non_upgrade_response(server: TestServer) -> None:
    server.respond_with = b"HTTP/1.1 404 Not Found\r\nContent-Length: 13\r\n\r\nno cable here"

    with pytest.raises(HandshakeError) as raised:
        await WebSocketTransport().dial(server.url, DialOptions())
    assert raised.value.status_code == 404
    assert raised.value.status == "404 Not Found"


async def test_web_socket_transport_does_not_follow_a_redirect(server: TestServer) -> None:
    server.respond_with = b"HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n"

    with pytest.raises(HandshakeError) as raised:
        await WebSocketTransport().dial(server.url, DialOptions())
    assert raised.value.status_code == 302


async def test_web_socket_transport_refuses_a_bad_accept_key(server: TestServer) -> None:
    server.bad_accept = True

    with pytest.raises(ActionCableError, match="Sec-WebSocket-Accept"):
        await WebSocketTransport().dial(server.url, DialOptions())


async def test_web_socket_transport_honors_cancellation(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    await server.accept()

    with pytest.raises(TimeoutError):
        async with asyncio.timeout(0.05):
            await conn.read()


async def test_client_over_the_real_transport(server: TestServer) -> None:
    """The whole cable dance over an actual WebSocket connection."""
    client = Client(server.url)

    connecting = start(client.connect())
    peer = await server.accept()
    await peer.write(OP_TEXT, b'{"type":"welcome"}')
    await connecting

    subscribing = start(client.subscribe(room()))
    assert await peer.read() == '{"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}"}'
    await peer.write(OP_TEXT, f'{{"type":"confirm_subscription","identifier":{_quote(ROOM_IDENTIFIER)}}}'.encode())

    subscription = await subscribing

    await peer.write(OP_TEXT, f'{{"identifier":{_quote(ROOM_IDENTIFIER)},"message":{{"body":"Hello!"}}}}'.encode())
    assert await receive(subscription) == '{"body":"Hello!"}'

    await subscription.perform("speak", {"body": "Hi!"})
    assert await peer.read() == (
        '{"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}",'
        '"data":"{\\"action\\":\\"speak\\",\\"body\\":\\"Hi!\\"}"}'
    )

    await client.close()


async def test_web_socket_transport_refuses_a_masked_server_frame(server: TestServer) -> None:
    conn = await dial(server, DialOptions())

    # RFC 6455 §5.1: a server must never mask, and a client that sees a masked
    # frame must fail the connection rather than quietly unmask it.
    await (await server.accept()).write_masked(OP_TEXT, b'{"type":"welcome"}')

    with pytest.raises(ActionCableError, match="masked"):
        await read(conn)


async def test_web_socket_transport_replies_to_a_close_once(server: TestServer) -> None:
    conn = await dial(server, DialOptions())
    peer = await server.accept()

    await peer.write(OP_CLOSE, (1000).to_bytes(2, "big"))
    with pytest.raises(CloseError):
        await read(conn)
    await conn.close()

    assert await peer.close_frames() == 1, "expected exactly one close frame in reply"


async def dial(server: TestServer, options: DialOptions, transport: WebSocketTransport | None = None) -> Conn:
    conn = await (transport or WebSocketTransport()).dial(server.url, options)
    server.hang_up(conn)

    return conn


async def read(conn: Conn) -> bytes:
    async with asyncio.timeout(WAIT):
        return await conn.read()


@dataclass
class Frame:
    final: bool
    opcode: int
    payload: bytes


class TestServer:
    """Speaks just enough of the server side of RFC 6455 to exercise the
    transport: it completes the handshake and then hands the raw connection
    over."""

    __test__ = False

    def __init__(self) -> None:
        self.bad_accept = False
        self.respond_with: bytes | None = None
        self.url = ""

        self._accepted: asyncio.Queue[PeerConn] = asyncio.Queue()
        self._peers: list[PeerConn] = []
        self._server: asyncio.Server | None = None
        self._hanging_up: list[Conn] = []

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        port = self._server.sockets[0].getsockname()[1]
        self.url = f"ws://127.0.0.1:{port}/cable"

    async def stop(self) -> None:
        for conn in self._hanging_up:
            await conn.close()

        # Both ends, and this end explicitly: from Python 3.12 a server's
        # wait_closed waits for every connection it accepted to go, not just
        # for the listener.
        for peer in self._peers:
            peer.writer.close()

        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()

    def hang_up(self, conn: Conn) -> None:
        """Close this connection when the test is over."""
        self._hanging_up.append(conn)

    async def accept(self) -> PeerConn:
        try:
            async with asyncio.timeout(WAIT):
                return await self._accepted.get()
        except TimeoutError:
            raise AssertionError("no client connected") from None

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        head = await reader.readuntil(b"\r\n\r\n")
        request, _, rest = head.partition(b"\r\n")
        target = request.decode().split(" ")[1]
        headers = Headers(
            dict(
                line.split(": ", 1)  # type: ignore[misc]
                for line in rest.decode().split("\r\n")
                if ": " in line
            )
        )

        if self.respond_with is not None:
            writer.write(self.respond_with)
            await writer.drain()
            writer.close()
            return

        accepted = accept_key(headers.get("Sec-WebSocket-Key", ""))
        if self.bad_accept:
            accepted = "obviously-wrong"

        response = (
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accepted}\r\n"
        )
        offered = headers.get("Sec-WebSocket-Protocol", "")
        if offered:
            response += f"Sec-WebSocket-Protocol: {offered.split(',')[0].strip()}\r\n"
        response += "\r\n"

        writer.write(response.encode())
        await writer.drain()

        peer = PeerConn(reader, writer, target=target, headers=headers)
        self._peers.append(peer)
        self._accepted.put_nowait(peer)


@dataclass
class PeerConn:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    target: str
    headers: Headers = field(default_factory=Headers)

    async def read(self) -> str:
        frame = await self.read_frame()
        assert frame.opcode == OP_TEXT, "expected a text frame"

        return frame.payload.decode()

    async def read_frame(self) -> Frame:
        async with asyncio.timeout(WAIT):
            return await self._try_read_frame()

    async def _try_read_frame(self) -> Frame:
        header = await self.reader.readexactly(2)

        frame = Frame(final=bool(header[0] & 0x80), opcode=header[0] & 0x0F, payload=b"")
        if not header[1] & 0x80:
            raise AssertionError("client sent an unmasked frame")

        length = header[1] & 0x7F
        if length == 126:
            length = int.from_bytes(await self.reader.readexactly(2), "big")
        elif length == 127:
            length = int.from_bytes(await self.reader.readexactly(8), "big")

        mask = await self.reader.readexactly(4)
        frame.payload = apply_mask(mask, await self.reader.readexactly(length))

        return frame

    async def write(self, opcode: int, payload: bytes) -> None:
        await self.write_fragment(opcode, payload, final=True)

    async def write_fragment(self, opcode: int, payload: bytes, *, final: bool) -> None:
        header = bytearray([opcode | (0x80 if final else 0)])
        length = len(payload)
        if length <= 125:
            header.append(length)
        elif length <= 0xFFFF:
            header.append(126)
            header += length.to_bytes(2, "big")
        else:
            header.append(127)
            header += length.to_bytes(8, "big")

        self.writer.write(bytes(header) + payload)
        await self.writer.drain()

    async def write_masked(self, opcode: int, payload: bytes) -> None:
        """Send a frame the way only a client is allowed to: masked."""
        mask = bytes([1, 2, 3, 4])
        header = bytes([0x80 | opcode, 0x80 | len(payload)]) + mask

        self.writer.write(header + apply_mask(mask, payload))
        await self.writer.drain()

    async def close_frames(self) -> int:
        """How many close frames the client sends before it goes away."""
        closes = 0

        while True:
            try:
                frame = await self.read_frame()
            except (AssertionError, TimeoutError, asyncio.IncompleteReadError, OSError):
                return closes
            if frame.opcode == OP_CLOSE:
                closes += 1


@pytest.fixture
async def server() -> AsyncIterator[TestServer]:
    running = TestServer()
    await running.start()

    yield running

    await running.stop()


def _quote(value: str) -> str:
    return json.dumps(value)
