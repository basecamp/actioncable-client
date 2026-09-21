"""Waiting on more than one thing, which asyncio has no one call for."""

from __future__ import annotations

import asyncio


async def first_of(*events: asyncio.Event) -> None:
    """Wait until any one of the events is set."""
    waiters = [asyncio.ensure_future(event.wait()) for event in events]

    try:
        await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for waiter in waiters:
            waiter.cancel()
