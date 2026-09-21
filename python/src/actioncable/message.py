"""The payload a channel broadcast or transmitted."""

from __future__ import annotations

import json
from typing import Any


class Message(str):
    """The undecoded payload a channel broadcast or transmitted.

    Its shape is entirely up to the channel, so call :meth:`json` to read it.
    The message is the JSON text as it arrived, so a ``Message`` is a ``str``
    and prints, compares and slices like one.
    """

    __slots__ = ()

    def json(self) -> Any:
        return json.loads(self)
