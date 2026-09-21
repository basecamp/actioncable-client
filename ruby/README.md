# actioncable-client

Ruby client for Rails' Action Cable.

The gem is `actioncable-client`, the require is `actioncable_client`, and
everything lives under `ActionCableClient`. That is deliberate: Rails already
owns `ActionCable` and `action_cable`, and a gem that defined
`ActionCable::Client` would be reaching into somebody else's namespace.

Ruby 3.2 or newer. No runtime dependencies.


## Installation

```bash
bundle add actioncable-client
```


## Getting started

```ruby
require "actioncable_client"

# Establish a connection
client = ActionCableClient.new("wss://example.com/cable")
client.connect(timeout: 10)

# Subscribe to a channel
room = client.subscribe(ActionCableClient::Identifier.new("RoomChannel", id: 42))

# Listen for incoming messages
Thread.new do
  room.each { |message| puts message.parse["body"] }
end

# Send messages
room.perform("speak", body: "Hello!")
```

`connect` opens a connection and waits for the server to acknowledge. Failed
attempts get retried automatically. Pass a timeout to control how long to wait:

```ruby
begin
  client.connect(timeout: 10)
rescue ActionCableClient::DisconnectError => disconnect
  raise unless disconnect.reason == ActionCableClient::Protocol::Reasons::UNAUTHORIZED

  sign_in_again
end
```

The errors worth handling, all of them under `ActionCableClient::Error`:

- `TimeoutError`, when the timeout runs out before the welcome arrives. It
  carries `last_error`, whatever the last attempt failed on, so a header that
  couldn't be built or a refused dial shows up in it.
- `DisconnectError`, when the server sends a disconnect message. `reason` is
  one of four strings, in `ActionCableClient::Protocol::Reasons`:
    * `UNAUTHORIZED` — authentication or authorization failed.
    * `INVALID_REQUEST` — the request wasn't a valid Action Cable upgrade.
    * `SERVER_RESTART` — the Rails server is restarting.
    * `REMOTE` — the app closed this connection with
      `ActionCable.server.disconnect`.
- `UnsupportedSubprotocolError`, when the server picks a protocol this client
  doesn't speak.
- `GaveUpError`, when `max_attempts:` is set and that many attempts failed in a
  row. It carries the last attempt's error as `last_error`.

A disconnect message says whether the client should re-connect. Only the ones
that say no raise. The rest are retried, so a server restart shows up in the
log and the connection returns on its own.

A `connect` that raises leaves the client stopped, with nothing running behind
it. Throw it away and make a new one. The one exception is
`AlreadyConnectedError`, which means a `connect` was already called on a client
that is running fine.

A client that stopped later on — the server hung up for good, or it ran out of
attempts — says so through `wait` and `error`:

```ruby
if client.wait(timeout: 30)
  logger.warn "cable stopped: #{client.error.message}"
end
```

`wait` blocks until the client has stopped and reports whether it has; with no
timeout it waits for as long as that takes. `error` is nil while the client
runs, and afterwards one of the errors above or `ClosedError`. A stopped client
doesn't come back; make a new one.

`subscribe` sends the subscription and waits for the channel to confirm it. It
raises `RejectedError` when the channel's `subscribed` method rejects it, and
takes a `timeout:` of its own.

Subscribing twice to the same identifier shares one subscription on the server.
Rails keeps one per identifier per connection and ignores a second subscribe,
so the client sends one, hands every message to each subscription, and tells
the server to unsubscribe when the last one does. A `subscribe` that finds the
identifier already confirmed returns right away; one that finds a subscribe
still in flight waits for its verdict.

An `Identifier` is a channel name and its params. A channel with no params
takes the name on its own, and `subscribe` accepts a bare string for it:

```ruby
client.subscribe("AppearanceChannel")
client.subscribe(ActionCableClient::Identifier.new("RoomChannel", id: 42))
```


## Reading messages

A subscription is an enumerable of the messages the channel sent it. `each`
blocks and yields until the subscription is unsubscribed, rejected, or the
client stops, so a loop over it ends on its own:

```ruby
room.each do |message|
  handle(message)
end

unless room.error.is_a?(ActionCableClient::UnsubscribedError)
  logger.warn "subscription ended: #{room.error.message}"
end
```

`error` on the subscription says which it was: `UnsubscribedError`,
`RejectedError`, or whatever stopped the client.

For a caller that would rather ask than be called back, `next_message` takes
one message, waiting at most as long as it is given. It returns nil once the
subscription has ended and nothing is left, and raises `TimeoutError` when the
wait runs out with the subscription still live:

```ruby
while (message = room.next_message(timeout: 5))
  handle(message)
end
```

A message is the raw JSON the channel sent. `parse` turns it into whatever the
channel meant, and `to_s` hands over the JSON as it arrived.

Read it promptly. A subscription buffers 64 messages, and a message that
arrives while the buffer is full gets dropped and logged rather than stalling
the connection. Set a bigger buffer if the reader can't keep up with a burst:

```ruby
client = ActionCableClient.new("wss://example.com/cable", message_buffer: 1000)
```

The buffer size applies to every subscription on the client.


## Authorizing the connection

Action Cable servers can authorize connections using cookies or headers.

Use `cookie:` to set a cookie when establishing a connection:

```ruby
client = ActionCableClient.new("wss://example.com/cable", cookie: "_session_id=...")
```

`header:` sets any other header:

```ruby
client = ActionCableClient.new("wss://example.com/cable", header: { "X-Api-Token" => "..." })
```

A credential that expires should use `header_provider:`, which runs on every
reconnect:

```ruby
client = ActionCableClient.new("wss://example.com/cable",
  header_provider: -> { { "Authorization" => "Bearer #{credentials.access_token}" } })
```

What it returns is merged over the headers already set, so an `Origin` or an
API token given with `header:` is kept. An error turns down that dial, and the
client tries again on its backoff.

When an application can identify an error that another connection attempt
cannot repair, use `stop_on_error:`. The client stops with the original error,
while other connection failures continue to retry:

```ruby
client = ActionCableClient.new("wss://example.com/cable",
  header_provider: -> { headers },
  stop_on_error: ->(error) { error.is_a?(SignedOut) })
```

Rails also checks the `Origin` header and rejects a request that doesn't carry
one. By default, the `Origin` is set to the server's URL, so
`wss://example.com/cable` sends `https://example.com`.

Set it explicitly when the server sees a different scheme or host than the URL
says, behind a proxy that terminates TLS for instance:

```ruby
client = ActionCableClient.new("wss://example.com/cable", origin: "http://example.com")
```


## Callbacks

Some channels only send what's new, so a reconnect can leave a gap. Only the
client knows a reconnect happened, so `subscribe` takes callbacks for the
connection events:

```ruby
room = client.subscribe(identifier,
  on_connected: ->(reconnected) { catch_up if reconnected },
  on_disconnected: ->(will_reconnect) { ... },
  on_rejected: -> { ... })
```

`on_connected` runs every time the server confirms the subscription.
`reconnected` is false the first time and true every time after.

`on_disconnected` runs when the connection drops. `will_reconnect` says whether
the client is coming back or has stopped for good.

`on_rejected` runs when the channel rejects the subscription.

Callbacks run on their own thread, one at a time, in order. `close`,
`subscribe` and `unsubscribe` all work from inside one. The message stream ends
only after the last callback has returned, so once an `each` over it ends, no
callback is still running or about to. A callback that raises takes its own
event down and nothing else: the error is logged and the next callback runs.

`unsubscribe` takes no timeout by default. The command goes out on the client's
own connection, so it works during a teardown that is already over time.


## Staying connected

Rails sends a ping every three seconds and the client watches for it. After six
seconds of silence the client treats the connection as dead, drops it, and
dials again after a second, then two, then four, up to thirty. Each delay
carries a little jitter, so a restarted server doesn't get every client back at
once.

Both are configurable, and the retrying can be capped:

```ruby
client = ActionCableClient.new("wss://example.com/cable",
  stale_after: 10,
  initial_backoff: 1,
  longest_backoff: 30,
  max_attempts: 10)
```

Every duration here is in seconds.

By default the client keeps dialing until `close`. With `max_attempts:` it
stops with `GaveUpError` after that many failures in a row; a welcome resets
the count, so it bounds one outage rather than the client's lifetime.

Subscriptions come back on their own. The client resubscribes all of them on
the new connection, then resends a subscribe every half second until the server
confirms it, because a subscribe that arrives before the connection is set up
gets dropped. The same subscription and the same message stream keep working
throughout.

Actions don't come back. `perform` and `send_data` raise `NotConnectedError`
while the connection is down, or up but not yet welcomed, since Rails discards
anything that arrives that early. Send it again if it matters.


## Testing

The in-memory transport the client's own tests run on ships with the gem, so
anything built on this client can drive one without a server:

```ruby
require "actioncable_client/testing"

transport = ActionCableClient::Testing::FakeTransport.new
client = ActionCableClient.new("ws://cable.test/cable", transport: transport)

connecting = Thread.new { client.connect }
server = transport.accept
server.welcome
connecting.join

subscribing = Thread.new { client.subscribe("RoomChannel") }
server.command
server.confirm(%({"channel":"RoomChannel"}))
room = subscribing.value

server.broadcast(%({"channel":"RoomChannel"}), { body: "Hello!" })
room.next_message(timeout: 1).parse  # => { "body" => "Hello!" }
```

Every wait on the fake takes a timeout and raises `TimeoutError` rather than
hanging, so a test that got the dance wrong fails instead of stalling.


## Swapping the transport

The client speaks over an RFC 6455 WebSocket of its own by default, written on
the standard library so the gem carries no dependencies.

An application that already uses a WebSocket library can keep using it. A
transport answers one message:

```ruby
dial(url, subprotocols:, headers:) # => a connection
```

`subprotocols` are what the client's protocols negotiate under, and `headers`
are what authorizes the request.

A connection answers four:

```ruby
subprotocol              # what the server picked, nil if it picked none
read(timeout:)           # the next complete message, as a String
write(payload, timeout:) # sends one text message
close                    # hangs up
```

`read` and `write` are each called from one thread at a time, but `close` may
be called alongside either and has to interrupt it. A `read` that runs out of
time raises `ActionCableClient::TimeoutError`, which is how the client notices
a connection has gone quiet.

Write both and hand the transport to the client:

```ruby
client = ActionCableClient.new(url, transport: FayeTransport.new)
```

The default is `ActionCableClient::WebSocketTransport`. Three of its failures
are typed, for a caller that wants to act on them rather than read them:

- `HandshakeError`, when the server answers the upgrade with anything but 101.
  `status_code` tells a redirect from a refusal.
- `CloseError`, from `read` when the server sends a close frame, with its
  `code` and `reason`.
- `MessageTooBigError`, from `read` when a message is larger than
  `max_message_size:`. It is refused as soon as its length is known, before any
  of it is read in.

Its connections also answer `close_with_status(code, reason)`, where `close`
sends 1000.


## Adding protocols

Action Cable servers can talk multiple protocols. Rails' default is V1-JSON and
that's what's supported out-of-the-box. But, if needed, new protocols can be
added. A protocol answers three messages:

```ruby
subprotocol      # the WebSocket subprotocol it negotiates under
encode(command)  # a Protocol::Command to bytes
decode(payload)  # bytes to a Protocol::Incoming
```

All protocols will be offered to the server in that order. If one protocol is
preferred over another then it should be listed first:

```ruby
client = ActionCableClient.new(url,
  protocols: [ V2MessagePack.new, ActionCableClient::Protocol::V1JSON.new ])
```

`additional_protocols:` is a shorthand for adding new protocols to the default
list. They get prepended, which means they'll be preferred:

```ruby
client = ActionCableClient.new(url, additional_protocols: [ V2MessagePack.new ])
```

The default is `Protocol::V1JSON`, which speaks `actioncable-v1-json`, Rails'
default protocol.


## Differences from the other clients

This is the Go client in Ruby, and behaves the same. Three things read
differently because Ruby does:

- **Errors are raised, not returned.** Everything descends from
  `ActionCableClient::Error`. Go's error wrapping becomes an attribute: a
  `GaveUpError` or a `TimeoutError` carries the failure it was waiting out as
  `last_error` rather than wrapping it.
- **`send` is `send_data`.** Every Ruby object already answers to `send` as the
  dynamic dispatcher, and taking that name on a subscription would be a trap.
  Its fields, and `perform`'s, are usually given as keywords —
  `room.perform("speak", body: "Hi!")` — so a channel whose own field is called
  `timeout` wants the hash form, `room.perform("speak", { timeout: 30 })`.
- **A callback that raises is logged, not fatal.** Go's panics take the process
  with them; a Ruby thread that died on a callback would take every later
  callback with it and never end the message stream, so the dispatcher logs the
  error and runs the next one.

One thing is bounded rather than interruptible: `close` waits for a dial that
is already in flight to finish, which the transport's own handshake timeout
bounds at ten seconds. Go cancels the dial's context instead.


## Contributing

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. Discussions come before
issues and pull requests.


## License

Released under the MIT License. See [LICENSE](../LICENSE).
