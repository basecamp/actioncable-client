# ActionCable

Swift client for Rails' Action Cable.

Requires Swift 6.0, iOS 16 or macOS 12. No dependencies.


## Installation

```swift
dependencies: [
    .package(url: "https://github.com/basecamp/actioncable-client", from: "2.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "ActionCable", package: "actioncable-client"),
    ]),
]
```


## Getting started

```swift
// Establish a connection
let client = ActionCableClient(url: "wss://example.com/cable")
try await client.connect()

// Subscribe to a channel
let room = try await client.subscribe(to: Identifier(channel: "RoomChannel", params: ["id": 42]))

// Listen for incoming messages
Task {
    for await message in room.messages {
        if let said = try? message.decode(Said.self) {
            print(said.body)
        }
    }
}

// Send messages
try await room.perform("speak", data: ["body": "Hello!"])
```

`connect` opens a connection and waits for the server to acknowledge. Failed
attempts get retried automatically. Cancelling the task that is waiting is how
you bound the wait:

```swift
let connecting = Task { try await client.connect() }
Task {
    try await Task.sleep(nanoseconds: 10_000_000_000)
    connecting.cancel()
}

do {
    try await connecting.value
} catch let disconnect as DisconnectError where disconnect.reason == .unauthorized {
    try await signInAgain()
}
```

The errors worth handling:

- `ActionCableError.connectCancelled`, when the task waiting for the welcome is
  cancelled. `lastAttempt` carries whatever the last attempt failed on, so a
  header that couldn't be built or a refused dial shows up in it.
- `DisconnectError`, when the server sends a disconnect message. `reason` is one
  of four:
    * `.unauthorized` — authentication or authorization failed.
    * `.invalidRequest` — the request wasn't a valid Action Cable upgrade.
    * `.serverRestart` — the Rails server is restarting.
    * `.remote` — the app closed this connection with
      `ActionCable.server.disconnect`.
- `ActionCableError.unsupportedSubprotocol`, when the server picks a protocol
  this client doesn't speak.
- `ActionCableError.gaveUp`, when `maxAttempts` is set and that many attempts
  failed in a row. `lastAttempt` is the last attempt's error.

A disconnect message says whether the client should re-connect. Only the ones
that say no throw. The rest are retried, so a server restart shows up in the log
and the connection returns on its own.

A `connect` that throws leaves the client stopped, with nothing running behind
it. Throw it away and make a new one. The one exception is
`ActionCableError.alreadyConnected`, which means `connect` was already called on
a client that is running fine.

A client that stopped later on — the server hung up for good, or it ran out of
attempts — says so through `waitUntilDone` and `error`:

```swift
await client.waitUntilDone()
print("cable stopped: \(await client.error as Any)")
```

`error` is nil while the client runs, and afterwards one of the errors above or
`ActionCableError.closed`. A stopped client doesn't come back; make a new one.

`subscribe` sends the subscription and waits for the channel to confirm it. It
throws `ActionCableError.rejected` when the channel's `subscribed` method
rejects it.

Subscribing twice to the same identifier shares one subscription on the server.
Rails keeps one per identifier per connection and ignores a second subscribe, so
the client sends one, hands every message to each `Subscription`, and tells the
server to unsubscribe when the last one does. A `subscribe` that finds the
identifier already confirmed returns right away; one that finds a subscribe
still in flight waits for its verdict.

`messages` ends when the subscription is unsubscribed, rejected, or the client
stops, so a `for await` loop over it finishes on its own. `error` on the
subscription says which it was: `.unsubscribed`, `.rejected`, or whatever
stopped the client.

```swift
for await message in room.messages {
    handle(message)
}
if case .unsubscribed? = room.error as? ActionCableError {
    // The subscription ended because we said so.
} else {
    print("subscription ended: \(room.error as Any)")
}
```

Read it promptly. A subscription buffers 64 messages, and a message that arrives
while the buffer is full gets dropped and logged rather than stalling the
connection. Set a bigger buffer if the reader can't keep up with a burst:

```swift
var configuration = ActionCableClient.Configuration()
configuration.messageBuffer = 1000

let client = ActionCableClient(url: "wss://example.com/cable", configuration: configuration)
```

The buffer size applies to every subscription on the client.


## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Everything a client can be told before it dials lives on a `Configuration`:

```swift
var configuration = ActionCableClient.Configuration()
configuration.cookie = "_session_id=..."
configuration.headers["X-Api-Token"] = "..."

let client = ActionCableClient(url: "wss://example.com/cable", configuration: configuration)
```

A credential that expires should use `headerProvider`, which runs on every
reconnect:

```swift
configuration.headerProvider = {
    ["Authorization": "Bearer \(try await credentials.accessToken())"]
}
```

What it returns is merged over the headers already set, so an `Origin` or an API
token given in `headers` is kept. An error turns down that dial, and the client
tries again on its backoff.

When an application can identify an error that another connection attempt cannot
repair, use `stopOnError`. The client stops with the original error, while other
connection failures continue to retry:

```swift
configuration.stopOnError = { $0 is SignedOut }
```

Rails also checks the `Origin` header and rejects a request that doesn't carry
one. By default, the origin is assumed from the server's URL, so
`wss://example.com/cable` sends `https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL
says, behind a proxy that terminates TLS for instance:

```swift
configuration.origin = "http://example.com"
```


## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the
client knows a reconnect happened, so `subscribe` takes callbacks for the
connection events:

```swift
let room = try await client.subscribe(
    to: identifier,
    onConnected: { reconnected in
        if reconnected {
            await catchUp()
        }
    },
    onDisconnected: { willReconnect in ... },
    onRejected: { ... }
)
```

`onConnected` runs every time the server confirms the subscription.
`reconnected` is false the first time and true every time after.

`onDisconnected` runs when the connection drops. `willReconnect` says whether
the client is coming back or has stopped for good.

`onRejected` runs when the channel rejects the subscription.

Callbacks run on a task of their own, one at a time, in order. `close`,
`subscribe` and `unsubscribe` all work from inside one. `messages` ends only
after the last callback has returned, so once a `for await` over it finishes, no
callback is still running or about to.

`unsubscribe` sends on the client's own task, so it works during a teardown
whose own task has already been cancelled.


## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six
seconds of silence the client treats the connection as dead, drops it, and dials
again after a second, then two, then four, up to thirty. Each delay carries a
little jitter, so a restarted server doesn't get every client back at once.

All of it is configurable, and the retrying can be capped:

```swift
configuration.staleAfter = 10
configuration.initialBackoff = 1
configuration.longestBackoff = 30
configuration.maxAttempts = 10
```

By default the client keeps dialing until `close`. With `maxAttempts` it stops
with `ActionCableError.gaveUp` after that many failures in a row; a welcome
resets the count, so it bounds one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on the
new connection, then resends a subscribe every half second until the server
confirms it, because a subscribe that arrives before the connection is set up
gets dropped. The same `Subscription` and the same `messages` stream keep
working throughout.

Actions don't come back. `perform` and `send` throw
`ActionCableError.notConnected` while the connection is down, or up but not yet
welcomed, since Rails discards anything that arrives that early. Send it again
if it matters.


## Swapping the transport

The client speaks over `URLSessionWebSocketTask` by default.

An application that already uses a WebSocket library can keep using it by
implementing two protocols.

`Transport` has one method:

```swift
public protocol Transport: Sendable {
    func dial(url: String, options: DialOptions) async throws -> any Connection
}
```

`dial` opens one connection. `options` carries the subprotocols the client's
protocols negotiate under, and the headers that authorize the request.

`Connection` has four members:

```swift
public protocol Connection: Sendable {
    var subprotocol: String { get }
    func read() async throws -> Data
    func write(_ payload: Data) async throws
    func close() async
}
```

`subprotocol` is what the server picked, empty if it picked none. `read` returns
the next complete message, and has to throw when the reading task is cancelled.
`write` sends one text message. `close` hangs up, and has to interrupt a `read`
or `write` running at the time.

Implement both and hand the transport to the client:

```swift
struct StarscreamTransport: Transport {
    func dial(url: String, options: DialOptions) async throws -> any Connection {
        ...
    }
}

configuration.transport = StarscreamTransport()
```

The default is `URLSessionTransport`, which carries no dependencies. Three of
its failures are typed, for a caller that wants to act on them rather than read
them:

- `HandshakeError`, when the server answers the upgrade with anything but 101.
  `statusCode` tells a redirect from a refusal.
- `CloseError`, from `read` when the server sends a close frame, with its `code`
  and `reason`.
- `ActionCableError.messageTooBig`, from `read` when a message is larger than
  `maximumMessageSize`.

Its connections also implement `StatusClosing`: `close(code:reason:)` hangs up
with a code and reason of the caller's choosing where `close()` sends 1000.


## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and
that's what's supported out of the box. But, if needed, new protocols can be
added.

`CableProtocol` has three members:

```swift
public protocol CableProtocol: Sendable {
    var subprotocol: String { get }
    func encode(_ command: Command) throws -> Data
    func decode(_ payload: Data) throws -> Incoming
}
```

`subprotocol` is the WebSocket subprotocol for the protocol. `encode` serializes
a command to the protocol's wire format, while `decode` does the opposite.

All protocols are offered to the server in order. If one is preferred over
another then it should come first:

```swift
configuration.protocols = [V2MessagePack(), V1JSON()]
```

`addProtocols` is shorthand for adding new protocols to the default list. They
are prepended, which means they're preferred:

```swift
configuration.addProtocols([V2MessagePack()])
```


## Testing against a fake

`ActionCableTesting` ships the in-memory transport this package's own tests use,
so an application can drive a client without a socket:

```swift
import ActionCableTesting

let transport = FakeTransport()
var configuration = ActionCableClient.Configuration()
configuration.transport = transport

let client = ActionCableClient(url: "ws://cable.example.com/cable", configuration: configuration)
async let connecting: Void = client.connect()

let connection = try await transport.accept()
try await connection.welcome()
try await connecting

let subscribing = Task { try await client.subscribe(to: Identifier(channel: "RoomChannel")) }
try await connection.expectCommand(.subscribe, #"{"channel":"RoomChannel"}"#)
try await connection.confirm(#"{"channel":"RoomChannel"}"#)
```


## Where this differs from the Go client

The Go client in `../go` is the model, and behaviour follows it. These are the
places it can't, and why.

**Types are top level, not namespaced.** `ActionCable.version` needs an
`ActionCable` enum, and an enum that shares the module's name shadows it — so
`ActionCable.Subscription` doesn't resolve. Every type is therefore reachable by
its bare name: `ActionCableClient`, `Subscription`, `Identifier`, `Message`,
`Transport`, `Connection`, `CableProtocol`, `CableLogger`. The two carrying a
prefix carry it because `Protocol` is taken by Objective-C and `Logger` by both
`os` and swift-log.

**A `Message` holds re-encoded JSON, not the server's bytes.** Go's
`json.RawMessage` hands the payload through untouched. Swift's decoder gives no
way to reach the bytes of a nested value, so the message is parsed and rendered
again with its object keys sorted. The value is the same; the byte order of a
multi-key object need not be.

**Cancellation stands in for `context.Context`.** `connect` and `subscribe` wait
until the task they run on is cancelled rather than until a deadline passes, and
throw `ActionCableError.connectCancelled` or `CancellationError` when it is.
`unsubscribe` and the unsubscribe a cancelled `subscribe` sends both go out on a
task of the client's own, which is what Go gets from writing on the client's
context rather than the caller's.

**`URLSessionWebSocketTask` does the RFC 6455 work, and hides some of it.** Go's
transport is a hand-written client over TCP; this one is `URLSession`, which
answers pings, masks, and reassembles on its own but does not expose everything
the Go transport reports:

- *The reason phrase of a refused upgrade.* `HandshakeError.statusCode` is the
  server's. `status` is built from Foundation's own name for that code, because
  `HTTPURLResponse` does not keep the phrase the server wrote.
- *A close code outside the ones `URLSession` names.*
  `URLSessionWebSocketTask.CloseCode` covers the codes RFC 6455 reserves and
  nothing in the private-use 4000–4999 range, so a `CloseError` cannot report an
  application's own code, and `close(code:reason:)` cannot send one — it falls
  back to 1000.
- *Refusing an oversized message before reading it in.* Go turns a message down
  as soon as its length is known. Here it is already in memory when
  `ActionCableError.messageTooBig` is thrown.
- *Headers nothing asked for.* `URLSession` adds `Accept`, `Accept-Encoding`,
  `Accept-Language` and `Connection` of its own. The session is ephemeral with
  cookie handling off, so nothing ambient beyond those goes out.
- *The close frame a `close(code:reason:)` should send.* Go writes one and the
  peer reads it. On Apple platforms `cancel(with:reason:)` is the only way to
  hang up, and on the macOS runner the peer sees the socket close without a
  close frame arriving first — whether or not a receive is pending, and however
  the session is let go. The connection still ends, which is what the client
  needs; what the peer is told about why is `URLSession`'s. The two tests that
  read the frame off the peer are skipped on Apple platforms and run on Linux,
  where swift-corelibs-foundation does write it.

**On Linux, swift-corelibs-foundation does less again.** These five differences
are what the test suite skips there, and every one of them is exercised on
Apple platforms:

- A message larger than about 16 KiB arrives in 16 KiB pieces, because libcurl
  hands its chunks over one at a time.
- A fragmented message arrives as one message per fragment.
- An upgrade whose `Sec-WebSocket-Accept` is wrong is accepted.
- A close frame carrying no code is reported as 1000 rather than 1005.
- A close code in the private-use range comes back as a different code
  altogether rather than as the invalid one.

For a Linux deployment that needs any of those, write a `Transport` over a
WebSocket package instead; the client itself is platform-independent.


## Contributing

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. Discussions come before issues
and pull requests.

Run `make check` before pushing.


## License

Released under the MIT License. See [LICENSE](../LICENSE).
