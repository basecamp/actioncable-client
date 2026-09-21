# actioncable

Python client for Rails' Action Cable. asyncio, no dependencies, fully typed.


## Installation

```bash
pip install actioncable-client
```


## Getting started

```python
import asyncio
import actioncable

# Establish a connection
client = actioncable.Client("wss://example.com/cable")
await client.connect(timeout=10)

# Subscribe to a channel
room = await client.subscribe(actioncable.Identifier("RoomChannel", {"id": 42}))

# Listen for incoming messages
async def listen():
    async for message in room:
        print(message.json()["body"])

listening = asyncio.create_task(listen())

# Send messages
await room.perform("speak", {"body": "Hello!"})
```

`connect` opens a connection and waits for the server to acknowledge. Failed
attempts get retried automatically. Pass a `timeout` to control how long to
wait:

```python
try:
    await client.connect(timeout=10)
except actioncable.DisconnectError as disconnect:
    if disconnect.reason == actioncable.REASON_UNAUTHORIZED:
        await sign_in_again()
    else:
        raise
```

The errors worth handling:

- `TimeoutError`, when `timeout` runs out before the welcome arrives, and
  `asyncio.CancelledError` when the task awaiting `connect` is cancelled. The
  timeout also names whatever the last attempt failed on, both in its message
  and as its `__cause__`, so a header that couldn't be built or a refused dial
  shows up in it.
- `DisconnectError`, when the server sends a disconnect message. `reason` is
  one of four strings:
    * `REASON_UNAUTHORIZED` — authentication or authorization failed.
    * `REASON_INVALID_REQUEST` — the request wasn't a valid Action Cable upgrade.
    * `REASON_SERVER_RESTART` — the Rails server is restarting.
    * `REASON_REMOTE` — the app closed this connection with
      `ActionCable.server.disconnect`.
- `UnsupportedSubprotocolError`, when the server picks a protocol this client
  doesn't speak.
- `GaveUpError`, when `max_attempts` is set and that many attempts failed in a
  row. Its `__cause__` is the last attempt's error.

Everything above descends from `ActionCableError`, so one `except` catches the
lot.

A disconnect message says whether the client should re-connect. Only the ones
that say no raise. The rest are retried, so a server restart shows up in the
log and the connection returns on its own.

A `connect` that raises leaves the client stopped, with nothing running behind
it. Throw it away and make a new one. The one exception is
`AlreadyConnectedError`, which means `connect` was already called on a client
that is running fine.

A client that stopped later on — the server hung up for good, or it ran out of
attempts — says so through `done` and `error`:

```python
await client.done()
print("cable stopped:", client.error)
```

`error` is `None` while the client runs, and afterwards one of the errors above
or `ClosedError`. A stopped client doesn't come back; make a new one.

`subscribe` sends the subscription and waits for the channel to confirm it. It
raises `RejectedError` when the channel's `subscribed` method rejects it.

Subscribing twice to the same identifier shares one subscription on the server.
Rails keeps one per identifier per connection and ignores a second subscribe,
so the client sends one, hands every message to each `Subscription`, and tells
the server to unsubscribe when the last one does. A `subscribe` that finds the
identifier already confirmed returns right away; one that finds a subscribe
still in flight waits for its verdict.

The message iterator ends when the subscription is unsubscribed, rejected, or
the client stops, so an `async for` over it finishes on its own. `error` on the
subscription says which it was: `UnsubscribedError`, `RejectedError`, or
whatever stopped the client.

```python
async for message in room:
    await handle(message)

if not isinstance(room.error, actioncable.UnsubscribedError):
    print("subscription ended:", room.error)
```

`room.messages()` is the same iterator, for code that would rather name it.

Read it promptly. A subscription buffers 64 messages, and a message that
arrives while the buffer is full gets dropped and logged rather than stalling
the connection. Set a bigger buffer if the reader can't keep up with a burst:

```python
client = actioncable.Client("wss://example.com/cable", message_buffer=1000)
```

The buffer size applies to every subscription on the client.

A `Message` is the JSON text the channel sent — it is a `str` — and `json()`
decodes it.


## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Use `cookie` to set a cookie when establishing a connection:

```python
client = actioncable.Client("wss://example.com/cable", cookie="_session_id=...")
```

`headers` sets any other header:

```python
client = actioncable.Client("wss://example.com/cable", headers={"X-Api-Token": "..."})
```

A credential that expires should use `headers_func`, which runs on every
reconnect and may be a coroutine function:

```python
async def authorization():
    return {"Authorization": f"Bearer {await credentials.access_token()}"}

client = actioncable.Client("wss://example.com/cable", headers_func=authorization)
```

What it returns is merged over the headers already set, so an `Origin` or an
API token given with `headers` is kept. An error turns down that dial, and the
client tries again on its backoff.

When an application can identify an error that another connection attempt
cannot repair, use `stop_on_error`. The client stops with the original error,
while other connection failures continue to retry:

```python
client = actioncable.Client(
    "wss://example.com/cable",
    headers_func=authorization,
    stop_on_error=lambda error: isinstance(error, SignedOut),
)
```

Rails also checks the `Origin` header and rejects a request that doesn't carry
one. By default, the `Origin` is set to the server's URL, so
`wss://example.com/cable` sends `https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL
says, behind a proxy that terminates TLS for instance:

```python
client = actioncable.Client("wss://example.com/cable", origin="http://example.com")
```


## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the
client knows a reconnect happened, so `subscribe` takes callbacks for the
connection events:

```python
async def connected(reconnected):
    if reconnected:
        await catch_up()

room = await client.subscribe(
    identifier,
    on_connected=connected,
    on_disconnected=lambda will_reconnect: ...,
    on_rejected=lambda: ...,
)
```

`on_connected` runs every time the server confirms the subscription.
`reconnected` is false the first time and true every time after.

`on_disconnected` runs when the connection drops. `will_reconnect` says whether
the client is coming back or has stopped for good.

`on_rejected` runs when the channel rejects the subscription.

Each callback may be a plain function or a coroutine function. They run on
their own task, one at a time, in order, so `close`, `subscribe` and
`unsubscribe` all work from inside one. The message iterator ends only after
the last callback has returned, so once an `async for` over it finishes, no
callback is still running or about to.

`unsubscribe` takes no deadline. The command goes out on the client's own
connection, so it works during a teardown whose timeout has already run out.


## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six
seconds of silence the client treats the connection as dead, drops it, and
dials again after a second, then two, then four, up to thirty. Each delay
carries a little jitter, so a restarted server doesn't get every client back at
once.

Both are configurable, and the retrying can be capped:

```python
client = actioncable.Client(
    "wss://example.com/cable",
    stale_after=10,
    backoff=(1, 30),
    max_attempts=10,
)
```

Durations are seconds, as everywhere else in asyncio.

By default the client keeps dialing until `close`. With `max_attempts` it stops
with `GaveUpError` after that many failures in a row; a welcome resets the
count, so it bounds one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on
the new connection, then resends a subscribe every half second until the server
confirms it, because a subscribe that arrives before the connection is set up
gets dropped. The same `Subscription` and the same message iterator keep
working throughout.

Actions don't come back. `perform` and `send` raise `NotConnectedError` while
the connection is down, or up but not yet welcomed, since Rails discards
anything that arrives that early. Send it again if it matters.


## Swapping the transport

The client speaks over its own RFC 6455 implementation by default, written on
`asyncio` streams and the `ssl` module.

An application that already uses a WebSocket library can keep using it by
implementing two protocols.

`Transport` has one method:

```python
class Transport(Protocol):
    async def dial(self, url: str, options: DialOptions) -> Conn: ...
```

`dial` opens one connection. `options` carries the subprotocols the client's
protocols negotiate under, and the headers that authorize the request.

`Conn` has four:

```python
class Conn(Protocol):
    @property
    def subprotocol(self) -> str: ...
    async def read(self) -> bytes: ...
    async def write(self, payload: bytes) -> None: ...
    async def close(self) -> None: ...
```

`subprotocol` returns the subprotocol the server picked, empty if it picked
none. `read` returns the next complete message. `write` sends one text message.
`close` hangs up, and has to interrupt a `read` or `write` running at the time.
Neither `read` nor `write` takes a deadline: the client bounds them by
cancelling the task, which is asyncio's way of saying what a context does in
Go.

Implement both and pass the transport to the client:

```python
import websockets

class WebsocketsTransport:
    async def dial(self, url, options):
        socket = await websockets.connect(
            url,
            subprotocols=options.subprotocols,
            additional_headers=dict(options.headers),
        )
        return WebsocketsConn(socket)

class WebsocketsConn:
    def __init__(self, socket):
        self._socket = socket

    @property
    def subprotocol(self):
        return self._socket.subprotocol or ""

    async def read(self):
        return await self._socket.recv()

    async def write(self, payload):
        await self._socket.send(payload)

    async def close(self):
        await self._socket.close()

client = actioncable.Client(url, transport=WebsocketsTransport())
```

The default is `WebSocketTransport`, which speaks RFC 6455 on the standard
library. Three of its failures are typed, for a caller that wants to act on
them rather than read them:

- `HandshakeError`, when the server answers the upgrade with anything but 101.
  `status_code` tells a redirect from a refusal.
- `CloseError`, from `read` when the server sends a close frame, with its
  `code` and `reason`.
- `MessageTooBigError`, from `read` when a message is larger than
  `max_message_size`. It is refused as soon as its length is known, before any
  of it is read in.

Its connections also implement `StatusCloser`: `close_with_status` hangs up
with a code and reason of the caller's choosing where `close` sends 1000.


## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and
that's what's supported out of the box. But, if needed, new protocols can be
added.

The `Protocol` protocol has just three members:

```python
class Protocol(Protocol):
    @property
    def subprotocol(self) -> str: ...
    def encode(self, command: Command) -> bytes: ...
    def decode(self, payload: bytes) -> Incoming: ...
```

`subprotocol` returns the WebSocket subprotocol for the protocol. `encode`
serializes a command to the protocol's wire format, while `decode` does the
opposite.

All protocols will be offered to the server in that order. If one protocol is
preferred over another then it should be listed first:

```python
client = actioncable.Client(url, protocols=[V2MessagePack(), actioncable.V1JSON()])
```

`additional_protocols` is shorthand for adding new protocols to the default
list. They are prepended, which means they'll be preferred:

```python
client = actioncable.Client(url, additional_protocols=[V2MessagePack()])
```

The default is `V1JSON`, which speaks `actioncable-v1-json`, Rails' default
protocol.


## Testing against it

`actioncable.testing` ships the in-memory transport this client's own tests are
written with, so an application's tests can play the server without a socket:

```python
from actioncable.testing import FakeTransport

transport = FakeTransport()
client = actioncable.Client("ws://cable.example.com/cable", transport=transport)

connecting = asyncio.create_task(client.connect())
conn = await transport.accept()
await conn.welcome()
await connecting

subscribing = asyncio.create_task(client.subscribe(actioncable.Identifier("RoomChannel")))
await conn.expect_command(actioncable.CommandName.SUBSCRIBE, '{"channel":"RoomChannel"}')
await conn.confirm('{"channel":"RoomChannel"}')
room = await subscribing

await conn.push('{"identifier":"{\\"channel\\":\\"RoomChannel\\"}","message":{"body":"Hello!"}}')
assert (await anext(aiter(room))).json() == {"body": "Hello!"}
```


## Where this differs from the Go client

The two behave alike; these are the places the language made the decision:

- **Cancellation is asyncio's.** Go passes a `context.Context` into `Connect`,
  `Subscribe`, `Perform` and `Send`. Here the caller cancels the task, or
  passes `timeout=` to `connect` and `subscribe` — which is also how the
  timeout can still name the failure it was waiting out, something an
  `asyncio.timeout()` wrapped around the call could not.
- **Errors are classes, not values.** `except RejectedError` does what
  `errors.Is(err, ErrRejected)` does, and `raise ... from ...` builds the chain
  `%w` builds.
- **`Message` is the JSON text, re-encoded.** Go keeps the exact bytes the
  server sent; Python's JSON decoder does not hand them back, so the text is
  encoded again from the decoded value. The value is the same, and only
  insignificant whitespace differs.
- **There are no locks.** Everything runs on one event loop, so the state Go
  guards with a mutex only changes between awaits. The one lock left is the one
  that keeps commands in order on the wire.
- **The logger is `logging`.** Pass `logger=` a `logging.Logger`; the default
  is the `actioncable` logger with a null handler, so nothing is emitted until
  an application configures logging.


## Contributing

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. Discussions come before
issues and pull requests.


## License

Released under the MIT License. See [LICENSE](../LICENSE).
