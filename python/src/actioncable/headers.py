"""A case-insensitive header map.

Go's client passes ``http.Header`` around. The standard library has no
equivalent outside ``http.client``, and this client only ever sets and gets one
value per name, so this is a plain mutable mapping that matches names without
regard to case and remembers the casing it was given.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping, MutableMapping


class Headers(MutableMapping[str, str]):
    def __init__(self, values: Mapping[str, str] | None = None) -> None:
        self._values: dict[str, tuple[str, str]] = {}
        if values is not None:
            self.update(values)

    def __getitem__(self, name: str) -> str:
        return self._values[name.lower()][1]

    def __setitem__(self, name: str, value: str) -> None:
        self._values[name.lower()] = (name, value)

    def __delitem__(self, name: str) -> None:
        del self._values[name.lower()]

    def __iter__(self) -> Iterator[str]:
        return (name for name, _ in self._values.values())

    def __len__(self) -> int:
        return len(self._values)

    def __repr__(self) -> str:
        return f"Headers({dict(self.items())!r})"

    def copy(self) -> Headers:
        return Headers(self)
