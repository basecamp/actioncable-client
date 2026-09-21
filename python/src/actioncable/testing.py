"""An in-memory transport a test plays the server on.

This is what the client's own tests drive it with, shipped because it is how
an application's tests will drive it too: no socket, no server, and every
frame the server sends written out by the test.

    transport = FakeTransport()
    client = actioncable.Client("ws://cable.example.com/cable", transport=transport)

    connecting = asyncio.create_task(client.connect())
    conn = await transport.accept()
    await conn.welcome()
    await connecting

Every helper that waits raises ``AssertionError`` when what it was waiting for
never happens, so a hung test fails with a sentence instead of a timeout.
"""

from __future__ import annotations

import asyncio
import json
from collections import deque
from dataclasses import dataclass
from typing import Any

from ._events import first_of
from .protocol import Command, CommandName, Incoming
from .transport import Conn, DialOptions
from .v1_json import SUBPROTOCOL_V1_JSON, V1JSON

WAIT = 2.0
"""How long a helper waits for something that should already have happened."""

QUIET = 0.1
"""How long a helper watches for something that should never happen."""


class FakeTransport:
    """Hands out in-memory connections a test can play the server on.

    ``write_buffer`` is how many commands a connection takes before a write
    waits on the test reading them. Zero makes every write wait, which lets a
    test hold the client mid-write.
    """

    def __init__(self, *, subprotocol: str = SUBPROTOCOL_V1_JSON, write_buffer: int = 32) -> None:
        self.subprotocol = subprotocol
        self.write_buffer = write_buffer
        self.dialed_with = DialOptions()

        self._dialed: deque[FakeConn] = deque()
        self._accepted = asyncio.Event()
        self._dial_errors: deque[BaseException] = deque()

    async def dial(self, url: str, options: DialOptions) -> Conn:
        self.dialed_with = options

        if self._dial_errors:
            raise self._dial_errors.popleft()

        conn = FakeConn(subprotocol=self.subprotocol, write_buffer=self.write_buffer)
        self._dialed.append(conn)
        self._accepted.set()

        return conn

    def fail_next_dial(self, error: BaseException) -> None:
        self._dial_errors.append(error)

    async def accept(self, timeout: float = WAIT) -> FakeConn:
        """The next connection the client dials."""
        try:
            async with asyncio.timeout(timeout):
                while not self._dialed:
                    self._accepted.clear()
                    await self._accepted.wait()
        except TimeoutError:
            raise AssertionError("no connection was dialed") from None

        return self._dialed.popleft()

    async def refuse_dial(self, quiet: float = QUIET * 2) -> None:
        """Assert the client dials nothing in the next little while."""
        await asyncio.sleep(quiet)

        if self._dialed:
            raise AssertionError(f"expected no connection, got one with subprotocol {self._dialed[0].subprotocol!r}")


class FakeConn:
    """One connection with the test playing the server on the other end.

    Like Rails it keeps one subscription per identifier: a subscribe for an
    identifier it has already heard, answered or not, is ignored.
    """

    def __init__(self, *, subprotocol: str = SUBPROTOCOL_V1_JSON, write_buffer: int = 32) -> None:
        self._subprotocol = subprotocol
        self._write_buffer = write_buffer
        self._subscribed: set[str] = set()

        self._incoming: deque[tuple[bytes, asyncio.Future[None]]] = deque()
        self._readable = asyncio.Event()
        self._outgoing: deque[tuple[bytes, asyncio.Future[None]]] = deque()
        self._sendable = asyncio.Event()
        self._drained = asyncio.Event()
        self._closed = asyncio.Event()

        # A tick as each write begins, so a test can tell the client is stuck
        # in one before anyone reads what it wrote.
        self.writing: asyncio.Queue[None] = asyncio.Queue()

    @property
    def subprotocol(self) -> str:
        return self._subprotocol

    async def read(self) -> bytes:
        while not self._incoming:
            if self._closed.is_set():
                raise ConnectionResetError("the fake connection is closed")
            self._readable.clear()
            await first_of(self._readable, self._closed)

        payload, taken = self._incoming.popleft()
        taken.set_result(None)

        return payload

    async def write(self, payload: bytes) -> None:
        if self._ignores(payload):
            return

        self.writing.put_nowait(None)

        taken: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        self._outgoing.append((payload, taken))
        self._sendable.set()

        while len(self._outgoing) > self._write_buffer and not taken.done():
            if self._closed.is_set():
                raise ConnectionResetError("the fake connection is closed")
            self._drained.clear()
            await first_of(self._drained, self._closed)

    async def close(self) -> None:
        self._closed.set()

    def _ignores(self, payload: bytes) -> bool:
        """Whether the server would drop the command without a word.

        Rails does that to a second subscribe for an identifier the connection
        already has.
        """
        try:
            command = json.loads(payload)
        except ValueError:
            return False

        return command.get("command") == CommandName.SUBSCRIBE and command.get("identifier") in self._subscribed

    async def push(self, frame: str) -> None:
        """Play a server frame to the client."""
        taken: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        self._incoming.append((frame.encode(), taken))
        self._readable.set()

        closing: asyncio.Future[Any] = asyncio.ensure_future(self._closed.wait())
        watching: list[asyncio.Future[Any]] = [taken, closing]
        try:
            async with asyncio.timeout(WAIT):
                await asyncio.wait(watching, return_when=asyncio.FIRST_COMPLETED)
        except TimeoutError:
            raise AssertionError(f"client never read {frame}") from None
        finally:
            closing.cancel()

        if not taken.done():
            raise AssertionError(f"connection closed before {frame} could be sent")

    async def welcome(self) -> None:
        await self.push('{"type":"welcome"}')

    async def confirm(self, identifier: str) -> None:
        await self.push(f'{{"type":"confirm_subscription","identifier":{_quote(identifier)}}}')

    async def reject(self, identifier: str) -> None:
        """Turn a subscription down, which also forgets it: the client is free
        to try again."""
        self._subscribed.discard(identifier)

        await self.push(f'{{"type":"reject_subscription","identifier":{_quote(identifier)}}}')

    async def sent(self) -> bytes:
        """The next payload the client writes, exactly as it went out."""
        try:
            async with asyncio.timeout(WAIT):
                while not self._outgoing:
                    self._sendable.clear()
                    await self._sendable.wait()
        except TimeoutError:
            raise AssertionError("client sent nothing") from None

        payload, taken = self._outgoing.popleft()
        taken.set_result(None)
        self._drained.set()

        return payload

    async def next(self) -> Command:
        """The next command the client sends. Nobody has heard it yet:
        :meth:`command` and :meth:`drop_command` settle that."""
        payload = await self.sent()

        try:
            decoded = json.loads(payload)
        except ValueError as error:
            raise AssertionError(f"decoding command {payload!r}: {error}") from None

        return Command(
            name=CommandName(decoded["command"]),
            identifier=decoded["identifier"],
            data=decoded.get("data", ""),
        )

    async def command(self) -> Command:
        """The next command the client sends, taken in the way the server
        would."""
        command = await self.next()
        self._hear(command)

        return command

    def _hear(self, command: Command) -> None:
        if command.name is CommandName.SUBSCRIBE:
            self._subscribed.add(command.identifier)
        elif command.name is CommandName.UNSUBSCRIBE:
            self._subscribed.discard(command.identifier)

    async def expect_command(self, name: CommandName, identifier: str) -> Command:
        command = await self.command()

        assert command.name is name, f"expected {name}, got {command.name}"
        assert command.identifier == identifier, f"expected {identifier}, got {command.identifier}"

        return command

    async def drop_command(self, name: CommandName, identifier: str) -> None:
        """Let the next command fall on the floor, the way the server drops a
        subscribe that reaches it before the connection is set up."""
        command = await self.next()

        assert command.name is name, f"expected {name}, got {command.name}"
        assert command.identifier == identifier, f"expected {identifier}, got {command.identifier}"

    async def expect_no_command(self, quiet: float = QUIET) -> None:
        """Assert the client sends nothing in the next little while."""
        await asyncio.sleep(quiet)

        if self._outgoing:
            raise AssertionError(f"expected no command, got {self._outgoing[0][0]!r}")


@dataclass(frozen=True)
class FakeProtocol:
    """Speaks a made-up subprotocol and stamps everything it encodes, so a test
    can tell which protocol the client settled on."""

    subprotocol: str
    stamp: bytes

    def encode(self, command: Command) -> bytes:
        return self.stamp + V1JSON().encode(command)

    def decode(self, payload: bytes) -> Incoming:
        return V1JSON().decode(payload.removeprefix(self.stamp))


def _quote(value: str) -> str:
    return json.dumps(value)


__all__ = [
    "QUIET",
    "WAIT",
    "FakeConn",
    "FakeProtocol",
    "FakeTransport",
]
