"""The task a subscription's callbacks run on."""

from __future__ import annotations

import asyncio
import logging
from collections import deque
from collections.abc import Callable
from inspect import isawaitable

Callback = Callable[[], object]


class Dispatcher:
    """Runs a subscription's callbacks on their own task, one at a time, in the
    order the events happened.

    Callbacks belong off the connection's task: an ``on_disconnected`` that
    closes the client or an ``on_connected`` that subscribes are both
    reasonable things to write, and both wait on work only the connection task
    can do. The queue is unbounded for the same reason — handing an event over
    must never block the connection.

    Once stopped it runs what it still holds, turns away anything handed to it
    after that, then calls ``after_stop``. That is how a subscription ends its
    message iterator only after its last callback has returned, with none left
    behind unrun.
    """

    def __init__(self, after_stop: Callable[[], None], logger: logging.Logger) -> None:
        self._pending: deque[Callback] = deque()
        self._stopping = False
        self._awake = asyncio.Event()
        self._after_stop = after_stop
        self._logger = logger
        self._task = asyncio.create_task(self._run(), name="actioncable-callbacks")

    def dispatch(self, callback: Callback | None) -> None:
        if callback is None or self._stopping:
            return

        self._pending.append(callback)
        self._awake.set()

    def stop(self) -> None:
        """Let the dispatcher finish what it has and go away.

        It doesn't wait, since a callback is allowed to be what stopped it.
        """
        if not self._stopping:
            self._stopping = True
            self._awake.set()

    async def _run(self) -> None:
        while True:
            await self._awake.wait()
            self._awake.clear()
            await self._drain()

            if self._stopping:
                self._after_stop()
                return

    async def _drain(self) -> None:
        while self._pending:
            await self._invoke(self._pending.popleft())

    async def _invoke(self, callback: Callback) -> None:
        try:
            result = callback()
            if isawaitable(result):
                await result
        except asyncio.CancelledError:
            raise
        except Exception:
            self._logger.exception("a subscription callback raised")
