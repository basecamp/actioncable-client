"""Rails' default Action Cable protocol."""

from __future__ import annotations

import json
from typing import Any

from .errors import ActionCableError
from .message import Message
from .protocol import Command, Incoming, Kind

SUBPROTOCOL_V1_JSON = "actioncable-v1-json"
"""The subprotocol every Rails Action Cable server speaks."""

_KINDS = {
    "welcome": Kind.WELCOME,
    "ping": Kind.PING,
    "disconnect": Kind.DISCONNECT,
    "confirm_subscription": Kind.CONFIRMATION,
    "reject_subscription": Kind.REJECTION,
}


class V1JSON:
    """The ``actioncable-v1-json`` protocol: JSON objects in text frames, keyed
    by command going out and by type coming in."""

    @property
    def subprotocol(self) -> str:
        return SUBPROTOCOL_V1_JSON

    def encode(self, command: Command) -> bytes:
        fields: dict[str, str] = {"command": str(command.name), "identifier": command.identifier}
        if command.data:
            fields["data"] = command.data

        return json.dumps(fields, separators=(",", ":")).encode()

    def decode(self, payload: bytes) -> Incoming:
        try:
            frame = json.loads(payload)
        except ValueError as error:
            raise ActionCableError(f"decoding {_truncate(payload, 200)}: {error}") from error
        if not isinstance(frame, dict):
            raise ActionCableError(f"decoding {_truncate(payload, 200)}: not a JSON object")

        # Anything without a recognized type is a channel message, which is how
        # the server sends them: an identifier and a message, and no type at all.
        return Incoming(
            kind=_KINDS.get(frame.get("type", ""), Kind.MESSAGE),
            identifier=frame.get("identifier", ""),
            message=_message(frame),
            reason=frame.get("reason", ""),
            reconnect=bool(frame.get("reconnect", False)),
        )


def _message(frame: dict[str, Any]) -> Message:
    """The message field as JSON text again.

    Go keeps the bytes the server sent, which Python's decoder does not hand
    back, so it is re-encoded. The value is the same; only insignificant
    whitespace is lost.
    """
    if "message" not in frame:
        return Message("")

    return Message(json.dumps(frame["message"], separators=(",", ":")))


def _truncate(payload: bytes, limit: int) -> str:
    text = payload.decode(errors="replace")

    if len(text) > limit:
        return text[:limit] + "…"
    else:
        return text
