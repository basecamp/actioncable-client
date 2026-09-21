from __future__ import annotations

import pytest

from actioncable import (
    REASON_SERVER_RESTART,
    V1JSON,
    ActionCableError,
    Command,
    CommandName,
    Incoming,
    Kind,
    Message,
)


def test_v1_json_subprotocol() -> None:
    assert V1JSON().subprotocol == "actioncable-v1-json"


def test_v1_json_encode() -> None:
    commands = [
        (
            Command(CommandName.SUBSCRIBE, '{"channel":"RoomChannel"}'),
            '{"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}',
        ),
        (
            Command(CommandName.UNSUBSCRIBE, '{"channel":"RoomChannel"}'),
            '{"command":"unsubscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}',
        ),
        (
            Command(CommandName.MESSAGE, '{"channel":"RoomChannel"}', '{"action":"speak"}'),
            '{"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\"}","data":"{\\"action\\":\\"speak\\"}"}',
        ),
    ]

    for command, encoded in commands:
        assert V1JSON().encode(command).decode() == encoded


def test_v1_json_decode() -> None:
    frames = [
        ('{"type":"welcome"}', Incoming(Kind.WELCOME)),
        ('{"type":"ping","message":1755400000}', Incoming(Kind.PING, message=Message("1755400000"))),
        (
            '{"type":"disconnect","reason":"server_restart","reconnect":true}',
            Incoming(Kind.DISCONNECT, reason=REASON_SERVER_RESTART, reconnect=True),
        ),
        (
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}',
            Incoming(Kind.CONFIRMATION, identifier='{"channel":"RoomChannel"}'),
        ),
        (
            '{"type":"reject_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}',
            Incoming(Kind.REJECTION, identifier='{"channel":"RoomChannel"}'),
        ),
        (
            '{"identifier":"{\\"channel\\":\\"RoomChannel\\"}","message":{"body":"Hello!"}}',
            Incoming(Kind.MESSAGE, identifier='{"channel":"RoomChannel"}', message=Message('{"body":"Hello!"}')),
        ),
        (
            '{"type":"something_new","identifier":"x","message":"anything"}',
            Incoming(Kind.MESSAGE, identifier="x", message=Message('"anything"')),
        ),
    ]

    for payload, expected in frames:
        assert V1JSON().decode(payload.encode()) == expected, payload


def test_v1_json_decode_garbage() -> None:
    with pytest.raises(ActionCableError):
        V1JSON().decode(b"not json")
