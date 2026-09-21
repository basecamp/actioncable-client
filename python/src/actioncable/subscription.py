"""One channel subscription on a client."""

from __future__ import annotations

import asyncio
import json
import logging
from collections import deque
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from functools import partial
from typing import TYPE_CHECKING, Any

from .dispatcher import Dispatcher
from .errors import ActionCableError, RejectedError, UnsubscribedError
from .message import Message
from .protocol import Command, CommandName

if TYPE_CHECKING:
    from .client import Client

OnConnected = Callable[[bool], object]
OnDisconnected = Callable[[bool], object]
OnRejected = Callable[[], object]


class Subscription:
    """One channel subscription on a client.

    Read what the channel sends by iterating the subscription, and talk back
    with :meth:`perform` or :meth:`send`.
    """

    def __init__(
        self,
        client: Client,
        identifier: str,
        buffer: int,
        logger: logging.Logger,
        on_connected: OnConnected | None = None,
        on_disconnected: OnDisconnected | None = None,
        on_rejected: OnRejected | None = None,
    ) -> None:
        self._client = client
        self._identifier = identifier
        self._logger = logger
        self._on_connected = on_connected
        self._on_disconnected = on_disconnected
        self._on_rejected = on_rejected

        self._stream = MessageStream(buffer)
        self._confirmed = asyncio.Event()
        self._rejected = asyncio.Event()
        self._closed = False
        self._reason: BaseException | None = None
        self._callbacks = Dispatcher(self._stream.end, logger)

    @property
    def key(self) -> str:
        """The JSON identifier the server knows this subscription by, and the
        one it echoes back on everything it sends here."""
        return self._identifier

    def messages(self) -> AsyncIterator[Message]:
        """Everything the channel broadcasts or transmits to this subscription.

        The iterator ends when the subscription is unsubscribed, rejected, or
        the client stops, once the last callback has returned — :attr:`error`
        says which it was.

        Read it promptly. Messages that arrive with the buffer full are dropped
        and logged rather than stalling the connection; ``message_buffer`` on
        the client sizes the buffer for a slow consumer.
        """
        return self._stream

    def __aiter__(self) -> AsyncIterator[Message]:
        return self._stream

    @property
    def error(self) -> BaseException | None:
        """Why the subscription ended: :class:`~actioncable.errors.UnsubscribedError`,
        :class:`~actioncable.errors.RejectedError`, or whatever stopped the
        client. ``None`` while the subscription is live."""
        return self._reason

    async def perform(self, action: str, data: Any = None) -> None:
        """Invoke an action on the channel — the equivalent of the JavaScript
        client's ``perform``. ``data`` must encode to a JSON object, and may be
        ``None``."""
        payload = _perform_payload(action, data)

        await self._client._send(Command(CommandName.MESSAGE, self._identifier, payload))

    async def send(self, data: Any) -> None:
        """Deliver ``data`` to the channel as-is, without naming an action.
        Rails routes it to the channel's ``receive`` method."""
        try:
            payload = json.dumps(data, sort_keys=True, separators=(",", ":"))
        except TypeError as error:
            raise ActionCableError(f"encoding data for {self._identifier}: {error}") from error

        await self._client._send(Command(CommandName.MESSAGE, self._identifier, payload))

    async def unsubscribe(self) -> None:
        """Tell the server to drop the subscription and end the message
        iterator."""
        last, _ = self._client._forget(self, UnsubscribedError())

        if last:
            await self._client._send(Command(CommandName.UNSUBSCRIBE, self._identifier))

    def _confirm(self, reconnected: bool) -> None:
        """Pass the server's verdict on.

        A holder that unsubscribed between the registration's holders being
        listed and this call has nothing to hear.
        """
        if self._closed:
            return

        # The callback is queued before the verdict is published: a subscribe
        # woken by the verdict may unsubscribe at once, and that must not get
        # ahead of the callback for the event that woke it.
        if self._on_connected is not None:
            self._callbacks.dispatch(partial(self._on_connected, reconnected))
        self._confirmed.set()

    def _reject(self) -> None:
        self._callbacks.dispatch(self._on_rejected)
        self._rejected.set()
        self._close(self._rejection())

    def _rejection(self) -> RejectedError:
        return RejectedError(self._identifier)

    def _disconnect(self, will_reconnect: bool) -> None:
        if self._on_disconnected is not None:
            self._callbacks.dispatch(partial(self._on_disconnected, will_reconnect))

    def _deliver(self, message: Message) -> bool:
        # A closed subscription has nothing left to receive, and nothing to report.
        if self._closed:
            return True

        return self._stream.put(message)

    def _close(self, reason: BaseException) -> None:
        """End the subscription for the reason given.

        Deliveries stop at once; the message iterator ends from the callback
        task, after the callbacks already queued have run, so a reader that
        sees it end knows no callback is behind it.
        """
        if not self._closed:
            self._closed = True
            self._reason = reason

        self._callbacks.stop()


class MessageStream(AsyncIterator[Message]):
    """The buffer between the connection and whoever is reading the messages.

    An ``asyncio.Queue`` would do most of this, but the end of the stream has
    to arrive even when the buffer is full — which is exactly when a queue has
    no room for a sentinel — so the two are kept apart.
    """

    def __init__(self, buffer: int) -> None:
        self._buffer = buffer
        self._queued: deque[Message] = deque()
        self._ready = asyncio.Event()
        self._ended = False

    def put(self, message: Message) -> bool:
        """Queue a message, reporting whether there was room for it."""
        if len(self._queued) >= self._buffer:
            return False

        self._queued.append(message)
        self._ready.set()

        return True

    def end(self) -> None:
        self._ended = True
        self._ready.set()

    def __aiter__(self) -> MessageStream:
        return self

    async def __anext__(self) -> Message:
        while not self._queued:
            if self._ended:
                raise StopAsyncIteration
            self._ready.clear()
            await self._ready.wait()

        return self._queued.popleft()


@dataclass
class Registration:
    """The server's one subscription for an identifier, and every
    :class:`Subscription` here that shares it.

    Rails keeps one subscription per identifier per connection and says nothing
    to a second subscribe for it, so the subscribe command, its verdict, and
    the retries until then belong to the identifier rather than to each holder.

    ``pending`` is set while a subscribe is out on the connection in hand with
    no verdict yet, ``confirmed`` once the server said yes on it. Both clear
    when the connection drops: the next one starts over. A new registration
    starts out pending, since the subscribe goes out right behind it.
    """

    holders: list[Subscription] = field(default_factory=list)
    pending: bool = True
    confirmed: bool = False


def _perform_payload(action: str, data: Any) -> str:
    fields: dict[str, Any] = {}

    if data is not None:
        try:
            fields = json.loads(json.dumps(data))
        except TypeError as error:
            raise ActionCableError(f"encoding data for {action!r}: {error}") from error
        if not isinstance(fields, dict):
            raise ActionCableError(f"data for {action!r} must encode to a JSON object")

    fields["action"] = action

    return json.dumps(fields, sort_keys=True, separators=(",", ":"))
