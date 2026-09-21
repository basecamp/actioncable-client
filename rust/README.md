# actioncable-client

Rust client for Rails' Action Cable, one of the [Action Cable
clients](../README.md) this repository ships. It is the Go client's behavior on
tokio: one connection, many channel subscriptions, reconnects on its own.


## Installation

```bash
cargo add actioncable-client
```

The crate is `actioncable-client` and the library is `actioncable`:

```rust
use actioncable::{Client, Identifier};
```

The default `websocket` feature brings the built-in transport, tokio-tungstenite over
rustls. Turn it off and the crate is the traits, the protocol and the client core, with no
network dependency at all; you bring the transport with `ClientBuilder::transport`, as
described under [Swapping the transport](#swapping-the-transport), and `build` returns
`Error::NoTransport` until you do:

```toml
actioncable-client = { version = "2.0.0", default-features = false }
```


## Getting started

```rust,no_run
use actioncable::{Client, Identifier};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct Said {
    body: String,
}

async fn chat() -> Result<(), actioncable::Error> {
    // Establish a connection
    let client = Client::builder("wss://example.com/cable").build()?;
    client.connect().await?;

    // Subscribe to a channel
    let room = client
        .subscribe(Identifier::new("RoomChannel").param("id", 42))
        .await?;

    // Listen for incoming messages
    let reader = room.clone();
    tokio::spawn(async move {
        while let Some(message) = reader.next().await {
            if let Ok(said) = message.decode::<Said>() {
                println!("{}", said.body);
            }
        }
    });

    // Send messages
    room.perform("speak", json!({ "body": "Hello!" })).await?;

    room.unsubscribe().await?;
    client.close().await;
    Ok(())
}
```

`build` fails on a header that isn't valid HTTP, and on having no transport to dial with.
Nothing touches the network until `connect`.

`connect` opens a connection and waits for the server to acknowledge. Failed attempts get
retried automatically. Where the Go client takes a `context`, this one takes nothing: wrap
the call in `tokio::time::timeout` to control how long to wait.

```rust,no_run
use std::time::Duration;
use actioncable::{Client, DisconnectReason, Error};

async fn connect(client: &Client) -> Result<(), Box<dyn std::error::Error>> {
    match tokio::time::timeout(Duration::from_secs(10), client.connect()).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(Error::Disconnected { reason: Some(DisconnectReason::Unauthorized), .. })) => {
            sign_in_again()
        }
        Ok(Err(error)) => Err(error.into()),
        Err(deadline) => {
            // The client is still dialing. Give up on it, or leave it running.
            let waiting_on = client.last_error();
            client.close().await;
            Err(Box::new(deadline))
        }
    }
}

fn sign_in_again() -> Result<(), Box<dyn std::error::Error>> {
    Ok(())
}
```

Dropping the `connect` future bounds the wait, not the client: it keeps dialing until
`close`. That is where this parts from the Go client, whose `Connect` stops the client when
its context ends — a dropped future in Rust is how a `select!` loses a race, and killing the
connection over that would surprise everyone. `last_error` says what the client is failing
on meanwhile, so a credential that can't be built doesn't hide behind a deadline.

The errors worth handling:

- `Error::Disconnected`, when the server sends a disconnect message that says not to come
  back. `reason` is the `DisconnectReason` it gave, or `None` when it gave none:
    * `Unauthorized` — authentication or authorization failed.
    * `InvalidRequest` — the request wasn't a valid Action Cable upgrade.
    * `ServerRestart` — the Rails server is restarting.
    * `Remote` — the app closed this connection with `ActionCable.server.disconnect`.
    * `Other(String)` — anything a future Rails might add.
- `Error::UnsupportedSubprotocol`, when the server picks a protocol this client doesn't
  speak, or picks none at all.
- `Error::GaveUp`, when `max_attempts` is set and that many attempts failed in a row. It
  carries the last attempt's error.

A disconnect message says whether the client should re-connect. Only the ones that say no
return an error. The rest are logged through `tracing` and retried, so a server restart
shows up in the log and the connection returns on its own. The `Error` docs list which
variants each method can return.

A client that stopped for good stays stopped. `connect` and `subscribe` return the error
that stopped it from then on, or `Error::Closed` after `close`. Calling `connect` on a
client that is already running returns `Error::AlreadyConnected`.

A client that stopped later on — the server hung up for good, or it ran out of attempts —
says so through `done` and `err`:

```rust,no_run
# use actioncable::Client;
# async fn watch(client: &Client) {
client.done().await;
println!("cable stopped: {:?}", client.err());
# }
```

`err` is `None` while the client runs, and afterwards one of the errors above or
`Error::Closed`. A stopped client doesn't come back; make a new one.

`subscribe` takes an `Identifier`, or a `SubscribeRequest` when there are callbacks to
attach, sends the subscription and waits for the channel to confirm it. It returns
`Error::Rejected` when the channel's `subscribed` method rejects it, and
`Error::NotConnected` before `connect`. Dropping the future, from a timeout say, forgets
the subscription and, when nothing else holds the identifier, tells the server to drop it
too; a confirmation that arrives later goes nowhere.

Subscribing twice to the same identifier gives two subscriptions that each get every
message. Rails holds one subscription per identifier per connection and ignores a second
subscribe for it, so the client asks once: a second `subscribe` joins the first, confirmed
at once if the first already was, and sharing its verdict if it is still waiting. The
server hears about the unsubscribe from the last of them.

`Subscription::next` returns `None` once the subscription is unsubscribed, rejected, or the
client is closed, so a `while let` loop over it ends on its own. `Subscription::err` says
which it was: `Error::Unsubscribed`, `Error::Rejected`, or whatever stopped the client.

```rust,no_run
# use actioncable::{Error, Subscription};
# async fn read(room: Subscription) {
while let Some(message) = room.next().await {
    println!("{message}");
}
if !matches!(room.err(), Some(Error::Unsubscribed)) {
    println!("subscription ended: {:?}", room.err());
}
# }
```

Handles are cheap to clone and share one stream: a message goes to whichever handle reads
it first. Dropping the last handle unsubscribes too, when it happens on a tokio runtime;
elsewhere it stops delivery, warns, and leaves the server holding the subscription until
the connection ends.

Read it promptly. A subscription buffers 64 messages, and a message that arrives while the
buffer is full gets dropped and logged rather than stalling the connection. Set a bigger
buffer if the reader can't keep up with a burst:

```rust,no_run
# use actioncable::Client;
let client = Client::builder("wss://example.com/cable")
    .message_buffer(1000)
    .build();
```

The buffer size applies to every subscription on the client.

`perform` names an action and takes data that encodes to a JSON object, since that is the
only shape Rails routes to an action; anything else is `Error::DataNotAnObject`. Pass `()`
to send the action alone. `send` delivers data as-is, without an action, to the channel's
`receive` method.

Actions don't come back after a reconnect. `perform` and `send` return
`Error::NotConnected` while the connection is down, or up but not yet welcomed, since Rails
discards anything that arrives that early. A write that fails partway returns
`Error::Transport` and drops the connection for a redial, since the socket is in doubt.
Send it again if it matters.


## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Use `cookie` to set a cookie when establishing a connection:

```rust,no_run
# use actioncable::Client;
let client = Client::builder("wss://example.com/cable")
    .cookie("_session_id=...")
    .build();
```

`header` sets any other header:

```rust,no_run
# use actioncable::Client;
let client = Client::builder("wss://example.com/cable")
    .header("X-Api-Token", "...")
    .build();
```

A header that isn't valid HTTP, one carrying a newline say, fails `build` with
`Error::InvalidHeader`. That is where the Go client's header-injection guard lives here:
the value is an `http::HeaderValue` from the moment it is given, so there is nothing to
neutralize later.

A credential that expires should come from a `HeaderProvider`, which is asked on every
dial, the first included. A closure returning a future is one:

```rust,no_run
use actioncable::{Client, Error};
use http::{HeaderMap, HeaderValue};

async fn access_token() -> Result<String, std::io::Error> {
    Ok("token".to_string())
}

let client = Client::builder("wss://example.com/cable")
    .header_provider(|| async {
        let token = access_token().await.map_err(Error::headers)?;
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).expect("a token is printable"),
        );
        Ok(headers)
    })
    .build();
```

So is a credentials type that implements the trait, which is how one that already knows
how to refresh itself plugs in:

```rust,no_run
use actioncable::{Client, Error, HeaderProvider};
use async_trait::async_trait;
use http::{HeaderMap, HeaderValue};

struct Credentials;

impl Credentials {
    async fn access_token(&self) -> Result<String, std::io::Error> {
        Ok("token".to_string())
    }
}

#[async_trait]
impl HeaderProvider for Credentials {
    async fn headers(&self) -> Result<HeaderMap, Error> {
        let token = self.access_token().await.map_err(Error::headers)?;
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).expect("a token is printable"),
        );
        Ok(headers)
    }
}

let client = Client::builder("wss://example.com/cable")
    .header_provider(Credentials)
    .build();
```

What it returns is merged over the headers already set, so an `Origin` or an API token
given with `header` is kept and a header the provider also names is replaced. An error,
wrapped with `Error::headers`, turns down that dial, and the client tries again on its
backoff.

When an application can identify an error that another connection attempt cannot repair,
use `stop_on_error`. The client stops with that error, while other connection failures
continue to retry:

```rust,no_run
# use actioncable::Client;
# #[derive(Debug, thiserror::Error)]
# #[error("sign in again")]
# struct SignedOut;
let client = Client::builder("wss://example.com/cable")
    .stop_on_error(|error| error.cause().is_some_and(|cause| cause.is::<SignedOut>()));
```

`Error::cause` hands back the error the transport or the header provider wrapped, for
`downcast_ref` to recognize. It is there rather than left to `std::error::Error::source`
because the wrapped error is held behind an `Arc`, and a `source` walk hands back the `Arc`
rather than what is in it.

Rails also checks the `Origin` header and rejects a request that doesn't carry one. By
default, the `Origin` is set to the server's URL, so `wss://example.com/cable` sends
`https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL says, behind
a proxy that terminates TLS for instance:

```rust,no_run
# use actioncable::Client;
let client = Client::builder("wss://example.com/cable")
    .origin("http://example.com")
    .build();
```

The built-in transport adds `User-Agent: actioncable/<version>` unless you set one. The
headers the upgrade handshake itself needs are its own and can't be overridden.


## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the client knows a
reconnect happened, so a `SubscribeRequest` takes callbacks for the connection events:

```rust,no_run
use actioncable::{Client, Identifier, SubscribeRequest};

async fn watch(client: &Client) -> Result<(), actioncable::Error> {
    let room = client
        .subscribe(
            SubscribeRequest::new(Identifier::new("RoomChannel"))
                .on_connected(|reconnected| async move {
                    if reconnected {
                        catch_up().await;
                    }
                })
                .on_disconnected(|will_reconnect| async move {
                    println!("gone, back soon: {will_reconnect}");
                })
                .on_rejected(|| async { println!("turned away") }),
        )
        .await?;
    Ok(())
}

async fn catch_up() {}
```

`on_connected` runs every time the server confirms the subscription. `reconnected` is
false the first time and true every time after.

`on_disconnected` runs when the connection drops. `will_reconnect` says whether the client
is coming back or has stopped for good.

`on_rejected` runs when the channel rejects the subscription.

Callbacks are async: each returns a future, and `|x| async move { .. }` is how a plain
closure becomes one. They run on their own tokio task, one at a time, in order, never on
the connection's task, and the next event waits for the current callback to finish.
`close`, `subscribe` and `unsubscribe` can all be awaited from inside one. The message
stream ends only after the last of them has returned, so a `while let` loop that ends knows
no callback is still running or about to.

The same events also arrive as a stream of `Event`s on every subscription, next to its
messages, for code that would rather read than be called:

```rust,no_run
use actioncable::{Event, Subscription};

async fn watch(room: Subscription) {
    while let Some(event) = room.next_event().await {
        match event {
            Event::Connected { reconnected: true } => catch_up(),
            Event::Connected { reconnected: false } => {}
            Event::Disconnected { will_reconnect } => println!("gone, back soon: {will_reconnect}"),
            Event::Rejected => break,
        }
    }
}

fn catch_up() {}
```

Events arrive in the order they happened. Callbacks and the stream see the same events;
neither takes from the other. A handle keeps the last sixteen events for a reader that
isn't listening, so a handle that never reads them costs nothing however long the client
runs; a reader further behind than that skips the oldest and is told so in the log. A
rejection of the first subscribe is also the `Error::Rejected` that `subscribe` returns, so
the stream only ever sees `Rejected` after a reconnect. It is the last event: the client
has already let go of the subscription.


## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six seconds of
silence the client treats the connection as dead, drops it, and dials again after a second,
then two, then four, up to thirty. Each delay is spread between half and the whole of that,
so a restarted server doesn't get every client back at once.

All of it is configurable, and the retrying can be capped:

```rust,no_run
# use std::time::Duration;
# use actioncable::Client;
let client = Client::builder("wss://example.com/cable")
    .stale_after(Duration::from_secs(10))
    .backoff(Duration::from_secs(1), Duration::from_secs(30))
    .max_attempts(10)
    .build();
```

By default the client keeps dialing until `close`. With `max_attempts` it stops with
`Error::GaveUp` after that many failures in a row; a welcome resets the count, so it bounds
one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on the new
connection, then resends a subscribe every half second until the server confirms it,
because a subscribe that arrives before the connection is set up gets dropped.
`subscribe_retry` changes the half second. The same `Subscription` keeps working
throughout.


## Swapping the transport

The client speaks over tokio-tungstenite with rustls by default, trusting the platform's
root certificates. That is `WebSocketTransport`, behind the `websocket` Cargo feature. It
bounds the TCP connect, TLS handshake and upgrade together at ten seconds, bounds each
write at ten seconds so a peer that stopped reading can't hold a `perform` forever, and
refuses messages over 8 MiB; all three are settable:

```rust,no_run
# use std::time::Duration;
# use actioncable::{Client, WebSocketTransport};
let client = Client::builder("wss://example.com/cable")
    .transport(
        WebSocketTransport::new()
            .handshake_timeout(Duration::from_secs(5))
            .write_timeout(Duration::from_secs(5)),
    )
    .build();
```

Three of its failures are typed, for a caller that wants to act on them rather than read
them:

- `Error::Handshake`, when the server answers the upgrade with anything but 101. `status`
  tells a redirect from a refusal, and prints as the whole status line.
- `Error::Close`, from `read` when the server sends a close frame, with its `code` and
  `reason`.
- `Error::MessageTooBig`, from `read` when a message is larger than `max_message_size`. It
  is refused as soon as its length is known, before any of it is read in.

An application that already uses a WebSocket library can keep using it by implementing two
traits.

`Transport` has one function:

```rust,ignore
#[async_trait]
pub trait Transport: Send + Sync {
    async fn dial(&self, url: &str, options: DialOptions) -> Result<Box<dyn Conn>, Error>;
}
```

`dial` opens one connection. `options` carries the subprotocols the client's protocols
negotiate under, and the headers that authorize the request.

`Conn` has four, and a fifth with a default:

```rust,ignore
#[async_trait]
pub trait Conn: Send + Sync {
    fn subprotocol(&self) -> Option<&str>;
    async fn read(&self) -> Result<Vec<u8>, Error>;
    async fn write(&self, payload: &[u8]) -> Result<(), Error>;
    async fn close(&self);
    async fn close_with_status(&self, code: u16, reason: &str) { self.close().await }
}
```

`subprotocol` returns the subprotocol the server picked, `None` if it picked none. `read`
returns the next complete message. `write` sends one text message. `close` hangs up, and
has to interrupt a `read` running at the time. The client reads from one task and writes
from another, one write at a time, so the two halves need their own locks.
`Error::transport` wraps whatever the library reports.

`close_with_status` is where the Go client's optional `StatusCloser` went: a Rust caller can
always call it, and the default forwards to `close`, so a transport whose library can't say
why hangs up all the same. The built-in one sends the code and as much of the reason as a
control frame has room for.

Implement both and hand the transport to the client. `ClientBuilder::transport` works with
or without the `websocket` feature: with it, it replaces the built-in transport; without
it, it is the only way to build a client, and `build` returns `Error::NoTransport` until it
is called:

```rust,ignore
let client = Client::builder("wss://example.com/cable")
    .transport(MyTransport::new())
    .build()?;
```

The tests do exactly this with an in-memory transport, `FakeTransport` in
`actioncable::test_support`. It is behind the `test-support` Cargo feature, so a crate built
on this client can drive its own tests through the same fake by turning the feature on in
its dev-dependency; a test accepts the connection the client dialed and plays the server
on it, welcome, confirmations and broadcasts included:

```toml
[dev-dependencies]
actioncable-client = { version = "2.0.0", features = ["test-support"] }
```

`Arc<T>` is a `Transport` whenever `T` is, and a `HeaderProvider` whenever `T` is one, so
one of either can be kept and handed to every client an application builds — which is also
how a fake gets into code that would otherwise build the real one.


## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and that's
what's supported out-of-the-box. But, if needed, new protocols can be added.

The `Protocol` trait has just three functions:

```rust,ignore
pub trait Protocol: Send + Sync {
    fn subprotocol(&self) -> &str;
    fn encode(&self, command: &Command) -> Result<Vec<u8>, Error>;
    fn decode(&self, payload: &[u8]) -> Result<Incoming, Error>;
}
```

`subprotocol` returns the WebSocket subprotocol for the protocol. `encode` serializes a
`Command` to the protocol's wire format, while `decode` does the opposite, into an
`Incoming` whose `Kind` says what the server sent.

All protocols are offered to the server in that order, followed by the
`actioncable-unsupported` sentinel so a server that speaks none of them can say so. If one
protocol is preferred over another then it should be listed first:

```rust,ignore
let client = Client::builder(url)
    .protocols(vec![Arc::new(V2MessagePack), Arc::new(V1Json)])
    .build()?;
```

`prefer_protocols` is this client's spelling of the Go client's `WithAdditionalProtocols`:
a shorthand for adding new protocols to the default list. These protocols get prepended to
the list of supported protocols, which means that they'll be preferred:

```rust,ignore
let client = Client::builder(url)
    .prefer_protocols(vec![Arc::new(V2MessagePack)])
    .build()?;
```

The default is `V1Json`, which speaks `actioncable-v1-json`, Rails' default protocol. A
list emptied with `protocols(vec![])` leaves nothing to offer, and `connect` returns
`Error::NoProtocols`.


## Where this differs from the Go client

The behavior is the Go client's. What the language moved:

- **No `context`.** `connect` and `subscribe` wait; `tokio::time::timeout` bounds them, and
  dropping the future cancels the wait rather than the client. `unsubscribe`, `perform` and
  `send` take nothing either, so a teardown has nothing to hold on to.
- **No logger.** The client's chatter goes to `tracing`, which is where a Rust application
  already looks, instead of a `WithLogger` of its own.
- **`Error` is one enum**, not a set of sentinels and struct errors. `Error::cause` is how
  an application recognizes the error it handed over, since the chain holds it behind an
  `Arc`.
- **`StatusCloser` is a defaulted method** on `Conn`, because Rust has no way to ask a trait
  object whether it also implements something else.
- **Header injection can't happen.** A header is an `http::HeaderValue` as soon as it is
  given, so the Go client's escaping on the way out is a `build` failure here instead.
- **Handles are clones, not separate subscriptions.** Cloning a `Subscription` shares one
  stream; subscribing twice to the same identifier is what gives two.

Each of those has a test under `tests/` asserting the Rust behavior, next to the Go test it
came from.


## Development

```bash
make check   # what CI runs: fmt, clippy, tests, docs, cargo deny
make test    # the tests alone
```


## License

Released under the MIT License. See [LICENSE](../LICENSE).
