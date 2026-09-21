# actioncable-client

Kotlin client for Rails' Action Cable.


## Installation

```kotlin
dependencies {
    implementation("com.basecamp:actioncable-client:2.0.0")
}
```

The client is a Kotlin Multiplatform library with one target today, the JVM.
The client, the protocol and the identifier live in `commonMain`; the built-in
transport is the JDK's own WebSocket, so it lives in `jvmMain`. A second target
is a source set, not a rewrite.


## Getting started

```kotlin
// Establish a connection
val client = ActionCableClient("wss://example.com/cable")

withTimeout(10.seconds) { client.connect() }

// Subscribe to a channel
val room = client.subscribe(Identifier("RoomChannel", mapOf("id" to 42)))

// Listen for incoming messages
launch {
    room.messages.collect { message ->
        println(message.decode<Said>().body)
    }
}

// Send messages
room.perform("speak", mapOf("body" to "Hello!"))
```

`connect` opens a connection and suspends until the server acknowledges.
Failed attempts get retried automatically. Wrap it in `withTimeout` to control
how long to wait:

```kotlin
try {
    withTimeout(10.seconds) { client.connect() }
} catch (disconnect: DisconnectException) {
    if (disconnect.reason == DisconnectReason.UNAUTHORIZED) {
        signInAgain()
    } else {
        throw disconnect
    }
}
```

The failures worth handling:

- `CancellationException`, when the coroutine ends before the welcome arrives.
  Its `cause` is the `ConnectCancelledException` the client recorded, which in
  turn wraps whatever the last attempt failed on — so a header that couldn't be
  built or a refused dial shows up in it, and in `client.error`.
- `DisconnectException`, when the server sends a disconnect message. `reason` is
  one of four strings:
    * `DisconnectReason.UNAUTHORIZED` — authentication or authorization failed.
    * `DisconnectReason.INVALID_REQUEST` — the request wasn't a valid Action
      Cable upgrade.
    * `DisconnectReason.SERVER_RESTART` — the Rails server is restarting.
    * `DisconnectReason.REMOTE` — the app closed this connection with
      `ActionCable.server.disconnect`.
- `UnsupportedSubprotocolException`, when the server picks a protocol this
  client doesn't speak.
- `GaveUpException`, when `maxAttempts` is set and that many attempts failed in
  a row. Its `cause` is the last attempt's failure.

A disconnect message says whether the client should re-connect. Only the ones
that say no throw. The rest are retried, so a server restart shows up in the log
and the connection returns on its own.

A `connect` that throws leaves the client stopped, with nothing running behind
it. Throw it away and make a new one. The one exception is
`AlreadyConnectedException`, which means `connect` was already called on a
client that is running fine.

A client that stopped later on — the server hung up for good, or it ran out of
attempts — says so through `done` and `error`:

```kotlin
client.done.join()
log("cable stopped: ${client.error}")
```

`error` is null while the client runs, and afterwards one of the failures above
or a `ClosedException`. A stopped client doesn't come back; make a new one.

`subscribe` sends the subscription and suspends until the channel confirms it.
It throws `RejectedException` when the channel's `subscribed` method rejects it.

Subscribing twice to the same identifier shares one subscription on the server.
Rails keeps one per identifier per connection and ignores a second subscribe, so
the client sends one, hands every message to each `Subscription`, and tells the
server to unsubscribe when the last one does. A `subscribe` that finds the
identifier already confirmed returns right away; one that finds a subscribe
still in flight waits for its verdict.

`messages` ends when the subscription is unsubscribed, rejected, or the client
stops, so a `collect` over it returns on its own. `error` on the subscription
says which it was: `UnsubscribedException`, `RejectedException`, or whatever
stopped the client.

```kotlin
room.messages.collect { handle(it) }
if (room.error !is UnsubscribedException) {
    log("subscription ended: ${room.error}")
}
```

Collect it promptly, and from one collector — the flow is one channel's worth of
messages, not a broadcast. A subscription buffers 64, and a message that arrives
while the buffer is full gets dropped and logged rather than stalling the
connection. Set a bigger buffer if the collector can't keep up with a burst:

```kotlin
val client = ActionCableClient("wss://example.com/cable", messageBuffer = 1000)
```

The buffer size applies to every subscription on the client.

Everything a client runs is on a scope of its own, not the caller's: a
connection outlives the coroutine that opened it and lives until `close`.


## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Use `cookie` to set a cookie when establishing a connection:

```kotlin
val client = ActionCableClient("wss://example.com/cable", cookie = "_session_id=...")
```

`headers` sets any other header:

```kotlin
val client = ActionCableClient(
    "wss://example.com/cable",
    headers = Headers.of("X-Api-Token" to "..."),
)
```

A credential that expires should use `buildHeaders`, which runs on every
reconnect:

```kotlin
val client = ActionCableClient(
    "wss://example.com/cable",
    buildHeaders = { Headers.of("Authorization" to "Bearer ${credentials.accessToken()}") },
)
```

What it returns is laid over the headers already set, so an `Origin` or an API
token given with `headers` is kept. Throwing turns down that dial, and the
client tries again on its backoff.

When an application can identify a failure that another connection attempt
cannot repair, use `stopOnError`. The client stops with the original failure,
while other connection failures continue to retry:

```kotlin
val client = ActionCableClient(
    "wss://example.com/cable",
    buildHeaders = ::headers,
    stopOnError = { it is SignedOutException },
)
```

Rails also checks the `Origin` header and rejects a request that doesn't carry
one. By default, the `Origin` is set to the server's URL, so
`wss://example.com/cable` sends `https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL
says, behind a proxy that terminates TLS for instance:

```kotlin
val client = ActionCableClient("wss://example.com/cable", origin = "http://example.com")
```

A header value carrying a carriage return or a newline would be two headers by
the time it reached the server, so `Headers` turns each into a space when it
takes the value.


## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the
client knows a reconnect happened, so `subscribe` takes callbacks for the
connection events:

```kotlin
val room = client.subscribe(
    identifier,
    onConnected = { reconnected -> if (reconnected) catchUp() },
    onDisconnected = { willReconnect -> ... },
    onRejected = { ... },
)
```

`onConnected` runs every time the server confirms the subscription.
`reconnected` is false the first time and true every time after.

`onDisconnected` runs when the connection drops. `willReconnect` says whether
the client is coming back or has stopped for good.

`onRejected` runs when the channel rejects the subscription.

Callbacks are suspending functions that run on their own coroutine, one at a
time, in order. `close`, `subscribe`, and `unsubscribe` all work from inside
one. `messages` ends only after the last callback has returned, so once a
`collect` over it returns, no callback is still running or about to.

`unsubscribe` needs no scope of its own. The command goes out on the client's
own connection, so it works during a teardown whose coroutine has already been
cancelled.


## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six
seconds of silence the client treats the connection as dead, drops it, and dials
again after a second, then two, then four, up to thirty. Each delay carries a
little jitter, so a restarted server doesn't get every client back at once.

All of it is configurable, and the retrying can be capped:

```kotlin
val client = ActionCableClient(
    "wss://example.com/cable",
    staleAfter = 10.seconds,
    initialBackoff = 1.seconds,
    longestBackoff = 30.seconds,
    maxAttempts = 10,
)
```

By default the client keeps dialing until `close`. With `maxAttempts` it stops
with a `GaveUpException` after that many failures in a row; a welcome resets the
count, so it bounds one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on the
new connection, then resends a subscribe every half second until the server
confirms it, because a subscribe that arrives before the connection is set up
gets dropped. The same `Subscription` and the same `messages` flow keep working
throughout.

Actions don't come back. `perform` and `send` throw `NotConnectedException`
while the connection is down, or up but not yet welcomed, since Rails discards
anything that arrives that early. Send it again if it matters.


## Swapping the transport

The client speaks over the JDK's WebSocket by default.

An application that already uses a WebSocket library can keep using it by
implementing two interfaces.

`Transport` has one function:

```kotlin
interface Transport {
    suspend fun dial(url: String, options: DialOptions): Conn
}
```

`dial` opens one connection. `options` carries the sub-protocols the client's
protocols negotiate under, and the headers that authorize the request.

`Conn` has four members:

```kotlin
interface Conn {
    val subprotocol: String
    suspend fun read(): ByteArray
    suspend fun write(payload: ByteArray)
    suspend fun close()
}
```

`subprotocol` is the one the server picked, empty if it picked none. `read`
answers with the next complete message. `write` sends one text message. `close`
hangs up, and has to wake a `read` or `write` suspended at the time.

Implement both and hand the transport to the client:

```kotlin
val client = ActionCableClient(url, transport = OkHttpTransport())
```

The default is `WebSocketTransport`, which runs on `java.net.http.WebSocket`, so
the library carries no HTTP dependency of its own. Three of its failures are
typed, for a caller that wants to act on them rather than read them:

- `HandshakeException`, when the server answers the upgrade with anything but
  101. `statusCode` tells a redirect from a refusal.
- `CloseException`, from `read` when the server sends a close frame, with its
  `code` and `reason`.
- `MessageTooBigException`, from `read` when a message is larger than
  `maxMessageSize`.

Its connections also implement `StatusCloser`: `closeWithStatus` hangs up with a
code and reason of the caller's choosing where `close` sends 1000. A reason
longer than the 123 bytes a close frame has room for is trimmed to fit.


## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and
that's what's supported out of the box. But, if needed, new protocols can be
added.

The `Protocol` interface has just three members:

```kotlin
interface Protocol {
    val subprotocol: String
    fun encode(command: Command): ByteArray
    fun decode(payload: ByteArray): Incoming
}
```

`subprotocol` is the WebSocket sub-protocol for the protocol. `encode`
serializes a command to the protocol's wire format, while `decode` does the
opposite.

All protocols will be offered to the server in that order. If one protocol is
preferred over another then it should be listed first:

```kotlin
val client = ActionCableClient(url, protocols = listOf(V2MessagePack, V1Json))
```

`additionalProtocols` is a shorthand for adding new protocols to the default
list. These protocols get prepended, which means that they'll be preferred.

```kotlin
val client = ActionCableClient(url, additionalProtocols = listOf(V2MessagePack))
```

The default is `V1Json`, which speaks `actioncable-v1-json`, Rails' default
protocol.


## Testing against a fake server

`com.basecamp:actioncable-client-testing` ships the same fake transport this
library's own tests are written against, so an application can drive its cable
code without a server:

```kotlin
dependencies {
    testImplementation("com.basecamp:actioncable-client-testing:2.0.0")
}
```

```kotlin
val transport = FakeTransport()
val client = ActionCableClient("ws://cable.example.com/cable", transport = transport)

val connecting = async { client.connect() }
val server = transport.accept()
server.welcome()
connecting.await()

val subscribing = async { client.subscribe(Identifier("RoomChannel")) }
server.expectCommand(CommandName.SUBSCRIBE, """{"channel":"RoomChannel"}""")
server.confirm("""{"channel":"RoomChannel"}""")

server.transmit("""{"channel":"RoomChannel"}""", """{"body":"Hello!"}""")
```

Like Rails, a `FakeConn` keeps one subscription per identifier and ignores a
second subscribe for one it already has.


## Where this differs from the Go client

This is a port of the Go client in `../go`, endpoint for endpoint and test for
test. Three things could not come across unchanged:

- **A cancelled `connect` throws even when the welcome beat it there.** Go
  returns nil when the deadline and the welcome land in the same instant,
  keeping the connection and calling it a success. A cancelled coroutine cannot
  succeed, so the cancellation propagates; the connection is kept all the same,
  and `client.isConnected` says so.
- **`HandshakeException.status` is the status code, not the status line.** Go
  reads `404 Not Found` off the wire. `java.net.http` drops reason phrases —
  HTTP/2 has none — so there is nothing to read. `statusCode` is the same either
  way.
- **`maxMessageSize` counts characters for a text message.** The JDK hands text
  over as a `CharSequence` without its encoded length. A character is never more
  than a UTF-8 byte, so the limit lets a little more text through than it would
  bytes. A binary message is counted in bytes.

Everything else — the defaults, the wire shapes, the retry and resubscribe
behavior, the order callbacks run in — is the same, and every `Test*` in
`../go/*_test.go` has a counterpart here.


## Contributing

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. Discussions come before issues
and pull requests.

```bash
./gradlew check   # everything CI runs: ktlint, compile, tests
./gradlew test    # the tests alone
./gradlew build   # the artifacts
./gradlew fmt     # rewrite sources in the house format
```

The build wants a JDK 17 or newer.


## License

Released under the MIT License. See [LICENSE](../LICENSE).
