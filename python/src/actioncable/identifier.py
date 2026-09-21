"""The name of one subscription."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from .errors import ActionCableError

Params = Mapping[str, Any]
"""The extra attributes that identify a subscription alongside its channel
name, like the id of the record a channel streams for."""


@dataclass(frozen=True)
class Identifier:
    """Names one subscription.

    It is encoded as a JSON object and the server treats that encoding as an
    opaque key, echoing it back on every frame it sends for the subscription.

        Identifier("RoomChannel", {"id": 42})

    A channel with no params needs only the name.
    """

    channel: str
    params: Params = field(default_factory=dict)

    @property
    def key(self) -> str:
        """The JSON the server knows this subscription by."""
        fields = {**self.params, "channel": self.channel}

        try:
            return json.dumps(fields, sort_keys=True, separators=(",", ":"))
        except TypeError as error:
            raise ActionCableError(f"encoding identifier for {self.channel!r}: {error}") from error

    def __str__(self) -> str:
        try:
            return self.key
        except ActionCableError:
            return f"{self.channel}({self.params})"
