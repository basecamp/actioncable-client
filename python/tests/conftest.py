from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator, Callable, Coroutine
from typing import Any

import pytest

from actioncable import Client, CommandName, Identifier, Message, Subscription
from actioncable.testing import WAIT, FakeConn, FakeTransport

ROOM_IDENTIFIER = '{"channel":"RoomChannel","id":42}'

NewClient = Callable[..., Client]


def room() -> Identifier:
    return Identifier("RoomChannel", {"id": 42})


@pytest.fixture
def transport() -> FakeTransport:
    return FakeTransport()


@pytest.fixture
async def new_client(caplog: pytest.LogCaptureFixture) -> AsyncIterator[NewClient]:
    """Builds clients that log into the test's output and are closed with it."""
    caplog.set_level(logging.INFO, logger="actioncable")
    clients: list[Client] = []

    def build(transport: Any, **options: Any) -> Client:
        client = Client("ws://cable.example.com/cable", transport=transport, **options)
        clients.append(client)

        return client

    yield build

    for client in clients:
        await client.close()


def start(coroutine: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]:
    """Run a coroutine that will not finish until the test plays the server."""
    return asyncio.create_task(coroutine)


async def welcomed(client: Client, transport: FakeTransport) -> FakeConn:
    """Connect a client and play the server's welcome, returning the connection
    the test can go on talking over."""
    connecting = start(client.connect())
    conn = await transport.accept()
    await conn.welcome()
    await connecting

    return conn


async def subscribed(client: Client, conn: FakeConn) -> Subscription:
    subscribing = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)

    return await subscribing


async def receive(subscription: Subscription) -> Message:
    try:
        async with asyncio.timeout(WAIT):
            return await anext(aiter(subscription))
    except StopAsyncIteration:
        raise AssertionError("messages ended") from None
    except TimeoutError:
        raise AssertionError("no message arrived") from None


async def ended(subscription: Subscription) -> None:
    """Assert the subscription's messages have ended."""
    try:
        async with asyncio.timeout(WAIT):
            message = await anext(aiter(subscription))
    except StopAsyncIteration:
        return
    except TimeoutError:
        raise AssertionError("messages never ended") from None

    raise AssertionError(f"messages are still delivering: {message}")


async def still_running(task: asyncio.Task[Any], quiet: float = 0.05) -> None:
    """Assert a task has not finished yet."""
    done, _ = await asyncio.wait([task], timeout=quiet)

    if done:
        raise AssertionError(f"task finished early: {task.result()}")


async def stopped(client: Client) -> None:
    """Assert the client stops for good, and soon."""
    try:
        async with asyncio.timeout(WAIT):
            await client.done()
    except TimeoutError:
        raise AssertionError("client kept running") from None
