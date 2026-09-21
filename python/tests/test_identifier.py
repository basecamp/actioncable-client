from __future__ import annotations

import pytest

from actioncable import ActionCableError, Identifier


def test_identifier_key() -> None:
    identifiers = [
        (Identifier("RoomChannel"), '{"channel":"RoomChannel"}'),
        (Identifier("RoomChannel", {"id": 42}), '{"channel":"RoomChannel","id":42}'),
        (
            Identifier("RoomChannel", {"id": 42, "since": "yesterday"}),
            '{"channel":"RoomChannel","id":42,"since":"yesterday"}',
        ),
    ]

    for identifier, key in identifiers:
        assert identifier.key == key
        assert str(identifier) == key, "str should be the key"


def test_identifier_key_refuses_params_it_cannot_encode() -> None:
    identifier = Identifier("RoomChannel", {"id": object()})

    with pytest.raises(ActionCableError):
        assert identifier.key

    assert str(identifier).startswith("RoomChannel(")
