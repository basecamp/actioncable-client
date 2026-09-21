# @37signals/actioncable

TypeScript client for Rails' Action Cable. ESM, strict types, no runtime
dependencies, Node 22.12+ and browsers.

## Installation

```bash
npm install @37signals/actioncable
```

## Getting started

```ts
import { Client } from "@37signals/actioncable";

// Establish a connection
const client = new Client("wss://example.com/cable");
await client.connect({ signal: AbortSignal.timeout(10_000) });

// Subscribe to a channel
const room = await client.subscribe({
  channel: "RoomChannel",
  params: { id: 42 },
});

// Listen for incoming messages
void (async () => {
  for await (const message of room) {
    console.log(message.json<{ body: string }>().body);
  }
})();

// Send messages
await room.perform("speak", { body: "Hello!" });
```

`connect` opens a connection and waits for the server to acknowledge. Failed
attempts get retried automatically. Pass a signal to control how long to wait:

```ts
try {
  await client.connect({ signal: AbortSignal.timeout(10_000) });
} catch (error) {
  if (error instanceof DisconnectError && error.reason === DisconnectReason.unauthorized) {
    return signInAgain();
  }
  throw error;
}
```

The errors worth handling:

- `AbortedError`, when the signal is aborted before the welcome arrives. Its
  `name` is the aborting reason's own — `TimeoutError` for an
  `AbortSignal.timeout`, `AbortError` for an `AbortController` — and its
  `cause` is the reason itself. Its message also names whatever the last
  attempt failed on, so a header that couldn't be built or a refused dial shows
  up in it.
- `DisconnectError`, when the server sends a disconnect message. `reason` is
  one of four strings, and `DisconnectReason` names them:
  - `unauthorized` — authentication or authorization failed.
  - `invalid_request` — the request wasn't a valid Action Cable upgrade.
  - `server_restart` — the Rails server is restarting.
  - `remote` — the app closed this connection with
    `ActionCable.server.disconnect`.
- `UnsupportedSubprotocolError`, when the server picks a protocol this client
  doesn't speak.
- `GaveUpError`, when `maxAttempts` is set and that many attempts failed in a
  row. Its `cause` is the last attempt's error.

A disconnect message says whether the client should re-connect. Only the ones
that say no reject. The rest are retried, so a server restart shows up in the
log and the connection returns on its own.

A `connect` that rejects leaves the client stopped, with nothing running behind
it. Throw it away and make a new one. The one exception is
`AlreadyConnectedError`, which means `connect` was already called on a client
that is running fine.

A client that stopped later on — the server hung up for good, or it ran out of
attempts — says so through `done` and `error`:

```ts
await client.done;
console.log("cable stopped:", client.error);
```

`error` is null while the client runs, and afterwards one of the errors above
or `ClosedError`. A stopped client doesn't come back; make a new one.

`subscribe` sends the subscription and waits for the channel to confirm it. It
rejects with `RejectedError` when the channel's `subscribed` method rejects it.

Subscribing twice to the same identifier shares one subscription on the server.
Rails keeps one per identifier per connection and ignores a second subscribe,
so the client sends one, hands every message to each `Subscription`, and tells
the server to unsubscribe when the last one does. A `subscribe` that finds the
identifier already confirmed returns right away; one that finds a subscribe
still in flight waits for its verdict.

## Reading messages

A subscription is an `AsyncIterable`, so `for await` over it reads what the
channel sends. `messages()` is the same thing by name, for handing the iterator
somewhere else:

```ts
for await (const message of room) {
  handle(message);
}
if (!(room.error instanceof UnsubscribedError)) {
  console.log("subscription ended:", room.error);
}
```

The iteration ends when the subscription is unsubscribed, rejected, or the
client stops, so the loop finishes on its own. `error` says which it was:
`UnsubscribedError`, `RejectedError`, or whatever stopped the client.

`onMessage` is the same thing event-shaped, for code that would rather hand
over a callback than own a loop:

```ts
const room = await client.subscribe(identifier, {
  onMessage: (message) => handle(message),
});
```

A subscription is read one way or the other, never both: `messages()` throws
once `onMessage` has the messages.

A `Message` is the channel's payload undecoded. `json<T>()` decodes it,
`toString()` is the JSON text.

Read it promptly. A subscription buffers 64 messages, and a message that
arrives while the buffer is full gets dropped and logged rather than stalling
the connection. Set a bigger buffer if the reader can't keep up with a burst:

```ts
const client = new Client("wss://example.com/cable", { messageBuffer: 1000 });
```

The buffer size applies to every subscription on the client.

## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Use `cookie` to set a cookie when establishing a connection:

```ts
const client = new Client("wss://example.com/cable", { cookie: "_session_id=..." });
```

`headers` sets any other header:

```ts
const client = new Client("wss://example.com/cable", {
  headers: { "X-Api-Token": "..." },
});
```

A credential that expires should use `headersFor`, which runs on every
reconnect:

```ts
const client = new Client("wss://example.com/cable", {
  headersFor: async (signal) => ({
    Authorization: `Bearer ${await credentials.accessToken(signal)}`,
  }),
});
```

What it returns is merged over the headers already set, so an `Origin` or an
API token given in `headers` is kept. A rejection turns down that dial, and the
client tries again on its backoff.

When an application can identify an error that another connection attempt
cannot repair, use `stopOnError`. The client stops with the original error,
while other connection failures continue to retry:

```ts
const client = new Client("wss://example.com/cable", {
  headersFor: headers,
  stopOnError: (error) => error instanceof SignedOutError,
});
```

Rails also checks the `Origin` header and rejects a request that doesn't carry
one. By default, the `Origin` is set to the server's URL, so
`wss://example.com/cable` sends `https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL
says, behind a proxy that terminates TLS for instance:

```ts
const client = new Client("wss://example.com/cable", {
  origin: "http://example.com",
});
```

Headers only reach the server under Node, where `NodeTransport` writes the
opening request itself. In a browser the request is the platform's, and neither
a `Cookie` nor an `Authorization` header is the page's to set — see "The two
built-in transports".

## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the
client knows a reconnect happened, so `subscribe` takes callbacks for the
connection events:

```ts
const room = await client.subscribe(identifier, {
  onConnected: (reconnected) => {
    if (reconnected) {
      catchUp();
    }
  },
  onDisconnected: (willReconnect) => { ... },
  onRejected: () => { ... },
});
```

`onConnected` runs every time the server confirms the subscription.
`reconnected` is false the first time and true every time after.

`onDisconnected` runs when the connection drops. `willReconnect` says whether
the client is coming back or has stopped for good.

`onRejected` runs when the channel rejects the subscription.

Callbacks run off the connection's flow, one at a time, in order, and an async
one is awaited before the next runs. `close`, `subscribe` and `unsubscribe` all
work from inside one. A subscription's messages end only after the last
callback has returned, so once a `for await` over it finishes, no callback is
still running or about to.

`unsubscribe` takes no signal. The command goes out on the client's own
connection, so it works during a teardown whose signal has already been
aborted.

## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six
seconds of silence the client treats the connection as dead, drops it, and
dials again after a second, then two, then four, up to thirty. Each delay
carries a little jitter, so a restarted server doesn't get every client back at
once.

Both are configurable, and the retrying can be capped:

```ts
const client = new Client("wss://example.com/cable", {
  staleAfter: 10_000,
  backoff: { initial: 1_000, longest: 30_000 },
  maxAttempts: 10,
});
```

Every duration is in milliseconds.

By default the client keeps dialing until `close`. With `maxAttempts` it stops
with a `GaveUpError` after that many failures in a row; a welcome resets the
count, so it bounds one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on
the new connection, then resends a subscribe every half second until the server
confirms it, because a subscribe that arrives before the connection is set up
gets dropped. The same `Subscription` and the same messages keep working
throughout.

Actions don't come back. `perform` and `send` reject with `NotConnectedError`
while the connection is down, or up but not yet welcomed, since Rails discards
anything that arrives that early. Send it again if it matters.

## The two built-in transports

The package ships two, and which one a client gets without asking depends on
where it is running:

| Runtime                     | Default              | Can send headers |
| --------------------------- | -------------------- | ---------------- |
| Node                        | `NodeTransport`      | Yes              |
| Browsers, and anything else | `WebSocketTransport` | No               |

`NodeTransport` speaks RFC 6455 on `node:net` and `node:tls` and writes the
opening request itself, so it carries no dependencies and sends exactly the
headers it is handed — which is what a session cookie or a bearer token needs.

`WebSocketTransport` wraps the platform's global `WebSocket`. A browser decides
what an opening WebSocket request carries, so headers are not this transport's
to send: cookies for the cable's own origin ride along by themselves, and a
token goes in the URL's query string.

Neither pulls the other in. `@37signals/actioncable` resolves through a
conditional export map: Node gets `dist/index.node.js`, and a browser bundler —
anything that sets the `browser` condition, or that resolves the default, which
is every bundler — gets `dist/index.js`, which has no `node:` import anywhere in
its graph. The subpaths `@37signals/actioncable/node` and
`@37signals/actioncable/web` name the two entry points outright, for a resolver
whose conditions don't say what you meant. Within one Node process the entry
that loaded first sets the default, so a program that imports both should name
the transport it wants rather than rely on the default.

Either way, `transport` overrides it:

```ts
import { Client, WebSocketTransport } from "@37signals/actioncable";

const client = new Client(url, { transport: new WebSocketTransport() });
```

`NodeTransport` takes a few knobs of its own — `handshakeTimeout`,
`writeTimeout`, `maxMessageSize` (8 MB by default), and the options passed
through to `net.connect` and `tls.connect`:

```ts
import { Client, NodeTransport } from "@37signals/actioncable/node";

const client = new Client(url, {
  transport: new NodeTransport({ maxMessageSize: 32 * 1024 * 1024 }),
});
```

Three of its failures are typed, for a caller that wants to act on them rather
than read them:

- `HandshakeError`, when the server answers the upgrade with anything but 101.
  `statusCode` tells a redirect from a refusal.
- `CloseError`, from `read` when the server sends a close frame, with its
  `code` and `reason`.
- `MessageTooBigError`, from `read` when a message is larger than
  `maxMessageSize`. It is refused as soon as its length is known, before any of
  it is read in.

Both transports' connections are also `StatusCloser`s: `closeWithStatus` hangs
up with a code and reason of the caller's choosing where `close` sends 1000.

## Swapping the transport

An application that already uses a WebSocket library can keep using it by
implementing two interfaces.

`Transport` has one method:

```ts
interface Transport {
  dial(url: string, options: DialOptions): Promise<Connection>;
}
```

`dial` opens one connection. `options` carries the subprotocols the client's
protocols negotiate under, the headers that authorize the request, and a signal
that bounds the dial.

`Connection` has four members:

```ts
interface Connection {
  readonly subprotocol: string;
  read(options?: TransferOptions): Promise<string>;
  write(payload: string, options?: TransferOptions): Promise<void>;
  close(): Promise<void>;
}
```

`subprotocol` is the one the server picked, empty if it picked none. `read`
answers with the next complete message. `write` sends one text message. `close`
hangs up, and has to interrupt a `read` or `write` running at the time.

Implement both and pass the transport to the client:

```ts
import WebSocket from "ws";

class WsTransport implements Transport {
  async dial(url: string, options: DialOptions): Promise<Connection> {
    const socket = new WebSocket(url, options.subprotocols, {
      headers: Object.fromEntries(options.headers ?? []),
    });
    await once(socket, "open");

    return new WsConnection(socket);
  }
}

const client = new Client(url, { transport: new WsTransport() });
```

## Testing

`@37signals/actioncable/testing` exports the fake transport this package tests
itself with: in-memory connections a test plays the server on.

```ts
import { Client } from "@37signals/actioncable";
import { FakeTransport } from "@37signals/actioncable/testing";

const transport = new FakeTransport();
const client = new Client("ws://example.com/cable", { transport });

const connecting = client.connect();
const connection = await transport.accept();
await connection.welcome();
await connecting;

const subscribing = client.subscribe({ channel: "RoomChannel" });
await connection.command();
await connection.confirm(`{"channel":"RoomChannel"}`);
const room = await subscribing;

await connection.broadcast(`{"channel":"RoomChannel"}`, { body: "Hello!" });
```

A `FakeConnection` says things — `welcome`, `ping`, `confirm`, `reject`,
`disconnect`, `broadcast`, `push` — and hears them: `command` takes the next
command the way Rails would, `next` reads one without hearing it, `sent` gives
the raw payload, and `expectNoCommand` proves nothing was sent. `writeBuffer`
set to zero holds the client mid-write.

## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and
that's what's supported out of the box. But, if needed, new protocols can be
added.

The `Protocol` interface has three members:

```ts
interface Protocol {
  readonly subprotocol: string;
  encode(command: Command): string;
  decode(payload: string): Incoming;
}
```

`subprotocol` is the WebSocket subprotocol for the protocol. `encode`
serializes a command to the protocol's wire format, while `decode` does the
opposite.

All protocols will be offered to the server in that order. If one protocol is
preferred over another then it should be listed first:

```ts
const client = new Client(url, { protocols: [new V2MessagePack(), new V1JSON()] });
```

`additionalProtocols` is shorthand for adding new protocols to the default
list. These protocols get put ahead of the defaults, which means they'll be
preferred:

```ts
const client = new Client(url, { additionalProtocols: [new V2MessagePack()] });
```

The default is `V1JSON`, which speaks `actioncable-v1-json`, Rails' default
protocol.

## Differences from the Go client

The two clients do the same thing; these are the places where TypeScript made a
different decision:

- **Errors are classes, not sentinels.** Go compares with `errors.Is` against
  package-level values; this compares with `instanceof` against exported
  classes, and a wrapped failure hangs off `cause` the way Go's `%w` wraps one.
- **A cancelled `connect` rejects with an `AbortedError`** rather than with the
  context error itself, so the error can also name what the client was waiting
  out. The original reason is its `cause`, and its `name` is copied from the
  reason, so the usual `error.name === "TimeoutError"` check works.
- **A header with a CRLF in it is refused at construction.** `headers` and
  `headersFor` go through the platform's `Headers`, which throws on a value
  that could end the request line. Go neutralizes it instead, and so does
  `NodeTransport` for anything that reaches it another way.
- **A `Message`'s text is canonical JSON**, re-encoded from the frame, where
  Go's `json.RawMessage` keeps the server's bytes verbatim. The value is the
  same; the whitespace may not be.
- **There are two built-in transports** rather than one, because there are two
  kinds of runtime. See the table above.

## Development

```bash
make check   # everything CI runs: format, lint, typecheck, test, build
make test
```

## License

Released under the MIT License. See [LICENSE](../LICENSE).
