# Porting the Action Cable client

This repository is becoming `actioncable-client`: one Action Cable client per language
Basecamp ships an SDK in, all modeled on the Go client in `go/`. This file is the brief
for writing one of those ports. Read it whole before touching a language directory.

## The languages, and where each lives

| Directory     | Language   | Package                                         | Runtime floor and stack                                              |
|---------------|------------|-------------------------------------------------|----------------------------------------------------------------------|
| `go/`         | Go         | `github.com/basecamp/actioncable-client/go`     | Exists. The model for everything below.                              |
| `typescript/` | TypeScript | npm `@37signals/actioncable`                    | ESM. Node 22+ and browsers. See "Built-in transports".               |
| `python/`     | Python     | PyPI `actioncable-client`, import `actioncable` | asyncio. Same Python floor as `basecamp-sdk/python`.                 |
| `ruby/`       | Ruby       | gem `actioncable-client`, `require "actioncable_client"`, module `ActionCableClient` | Threads. Same Ruby floor as `basecamp-sdk/ruby`. |
| `kotlin/`     | Kotlin     | Maven `com.basecamp:actioncable-client`, package `com.basecamp.actioncable` | Coroutines. Same Gradle/Kotlin setup as `basecamp-sdk/kotlin`. |
| `rust/`       | Rust       | crate `actioncable-client`, lib `actioncable`   | tokio. Starts from the hey-linux port (see "The Rust base").         |
| `swift/`      | Swift      | SwiftPM package and product `ActionCable`       | Swift concurrency. Same platforms as `basecamp-sdk/Package.swift`.  |

The Ruby names avoid Rails' own `ActionCable` constant and `action_cable` require path on
purpose: a gem that defined `ActionCable::Client` would be reaching into Rails' namespace.

The layout copies `~/Work/basecamp/basecamp-sdk`: one directory per language, each a
complete, independently buildable package with its own README, and a root that ties them
together. When a convention is not stated here, do what `basecamp-sdk/<language>` does:
its lint and format configuration, its test runner, its minimum runtime version, the
shape of its Makefile or build file, and the steps its job in
`basecamp-sdk/.github/workflows/test.yml` runs. Read those before writing anything.

## What a port is

A port is the Go client, in another language, with the same three pluggable pieces and
the same behavior. Read `go/README.md` first for the user's view, then `go/*.go` for the
mechanics. Do not read `go/*_test.go` for style; read them for behavior, as described
under "Tests".

The three pieces:

- **Transport** carries bytes. `Dial(url, {subprotocols, headers}) -> Conn`, and a `Conn`
  with `Subprotocol()`, `Read()`, `Write(text)`, `Close()`. An optional `StatusCloser`
  adds `CloseWithStatus(code, reason)`. The built-in one speaks RFC 6455.
- **Protocol** speaks one wire format under one subprotocol name: `Subprotocol()`,
  `Encode(Command)`, `Decode(bytes) -> Incoming`. `V1JSON` implements
  `actioncable-v1-json`. The client offers every protocol it was given plus the
  `actioncable-unsupported` sentinel, and speaks the one the server picked.
- **Client** owns one connection and multiplexes subscriptions over it: connect and wait
  for the welcome, resubscribe after every welcome, resend unconfirmed subscribes on the
  guarantor interval, treat a quiet connection as dead after `staleAfter`, back off with
  jitter, give up after `maxAttempts`, stop for good on a non-reconnect disconnect or an
  unsupported subprotocol.

The public surface, in Go's names. Translate each to your language's idiom, keep every
one of them, and keep the semantics the Go doc comments state:

- `New(url, options...)`, `Connect(ctx)`, `Connected()`, `Done()`, `Err()`,
  `Subscribe(ctx, identifier, subscriptionOptions...)`, `Close()`.
- `Subscription`: `Key()`, `Messages()`, `Err()`, `Perform(ctx, action, data)`,
  `Send(ctx, data)`, `Unsubscribe()`.
- `Identifier{Channel, Params}` and its JSON key; `Message` as raw JSON with a decode helper.
- Options: `WithTransport`, `WithProtocols`, `WithAdditionalProtocols`, `WithHeader`,
  `WithHeaderFunc`, `WithStopOnError`, `WithCookie`, `WithOrigin`, `WithLogger`,
  `WithStaleAfter`, `WithBackoff`, `WithMaxAttempts`, `WithSubscribeRetry`,
  `WithMessageBuffer`.
- Subscription callbacks: `OnConnected(reconnected)`, `OnDisconnected(willReconnect)`,
  `OnRejected()`. They run off the connection's thread of control, one at a time, in
  order, and the last one has returned before `Messages` ends.
- Errors: `ErrClosed`, `ErrNotConnected`, `ErrRejected`, `ErrUnsupportedSubprotocol`,
  `ErrAlreadyConnected`, `ErrNoProtocols`, `ErrGaveUp`, `ErrUnsubscribed`,
  `ErrMessageTooBig`; `DisconnectError{Reason, Reconnect}`, `HandshakeError{StatusCode,
  Status}`, `CloseError{Code, Reason}`. The four disconnect reason constants.
- Defaults: stale after 6s, subscribe retry 500ms, backoff 1s doubling to 30s with
  jitter, unlimited attempts, message buffer 64, Origin assumed from the cable URL unless
  given, handshake timeout 10s, write timeout 10s, max message 8 MB.

Idiom wins on form, never on behavior. Go's channels become your language's stream or
async iterator, `context.Context` becomes your cancellation or timeout idiom, functional
options become a builder, keyword arguments or an options object, and a `Done()` channel
becomes whatever lets a caller wait for the client to stop. Name things the way your
language's standard library would. Where the Go code has a comment explaining a decision
the port shares, carry the explanation over in your own words; where the port makes a
different decision because the language does, write that down instead.

## Built-in transports

The Go transport is written on the standard library so the package carries no
dependencies. Each port does the same wherever the platform gives it a socket:

- **TypeScript**: two transports. `NodeTransport`, RFC 6455 on `node:net` and `node:tls`,
  is the default under Node and the only one that can send headers, which cookies and
  bearer tokens need. `WebSocketTransport` wraps the platform's global `WebSocket` for
  browsers and other runtimes, where headers are the browser's business. Package exports
  must not pull `node:` modules into a browser bundle; use a conditional export or a
  separate entry point.
- **Python**: RFC 6455 on `asyncio` streams with the `ssl` module. No dependency.
- **Ruby**: RFC 6455 on `Socket` and `OpenSSL`. No dependency.
- **Kotlin**: JVM `java.net.http.WebSocket`. If `basecamp-sdk/kotlin` is multiplatform,
  keep the client core in common code and the transport in the JVM source set.
- **Rust**: `tokio-tungstenite` over rustls with native roots, as the hey-linux base has
  it, behind a `websocket` feature so the core has no network dependency.
- **Swift**: `URLSessionWebSocketTask`.

Every built-in transport, like Go's: negotiates the subprotocols it is handed, sends the
headers it is handed and nothing else ambient, refuses a non-101 upgrade as a
`HandshakeError` with the status, never follows a redirect, answers pings, reassembles
fragments, refuses an oversized message before reading it in, and reports a peer close as
`CloseError`.

## The Rust base

A Rust port of the Go client already exists in hey-linux's history, written against an
earlier Go version. It is extracted at
`/home/stanko/.claude/jobs/c2d298ae/tmp/rust-base/crates/actioncable`. Start from it:
make it a standalone crate (it inherited edition, lints and dependency versions from a
workspace), and bring it to parity with today's Go client, including the typed transport
errors, `StatusCloser`, `WithAdditionalProtocols`, `WithHeaderFunc` and
`WithMaxAttempts`, checking each Go test has a Rust counterpart.

## Tests

The Go test files are the behavior specification. Every `Test*` in `go/*_test.go` has a
counterpart in the port, named the same way in the port's naming convention, asserting
the same thing through the same public surface. They fall into four groups:

- `client_test.go` drives the client over an in-memory fake transport the test plays the
  server on (`fake_transport_test.go`). Port the fake too; it is how the port's own users
  will test.
- `websocket_test.go` drives the built-in transport against a real loopback server that
  does the upgrade by hand. Port that server; it is what proves the RFC 6455 code.
- `protocol_v1_json_test.go` and `identifier_test.go` are pure encode and decode tests.
- `example_test.go` is documentation; each port's README carries the equivalent.

A port with fewer tests than Go is not finished. A behavior a test cannot express in your
language gets a note in the port's README saying what differs and why.

## Version and the release pipeline

One version number covers every language, and a script at the root rewrites it
everywhere, the way `basecamp-sdk/scripts/bump-version.sh` does. The initial version
is `2.0.0`: the Go module's path changes with this layout, and the other languages are
new. Put the version constant exactly here, so the script can find it:

| Language   | Where the version lives                                                       |
|------------|-------------------------------------------------------------------------------|
| Go         | `go/version.go`: `const Version = "2.0.0"`                                    |
| TypeScript | `typescript/package.json` `"version"`, and `typescript/src/version.ts`: `export const VERSION = "2.0.0";` |
| Python     | `python/pyproject.toml` `[project] version`, and `python/src/actioncable/_version.py`: `VERSION = "2.0.0"` |
| Ruby       | `ruby/lib/actioncable_client/version.rb`: `  VERSION = "2.0.0"`               |
| Kotlin     | `kotlin/build.gradle.kts`: `version = "2.0.0"` inside `allprojects`, and `kotlin/client/src/commonMain/kotlin/com/basecamp/actioncable/Version.kt`: `const val VERSION = "2.0.0"` |
| Rust       | `rust/Cargo.toml` `version = "2.0.0"`                                          |
| Swift      | `swift/Sources/ActionCable/Version.swift`: `public static let version = "2.0.0"` on an `ActionCable` enum |

Each language directory has a `Makefile` (or, for Kotlin, Gradle tasks the root Makefile
calls) with `check`, `fmt`, `lint`, `test` and `build` targets, `check` being everything
CI runs for that language. The root Makefile, the CI workflow and the release workflows
are written after the ports, against those targets and version paths; a port that
deviates from the table breaks them.

## Ground rules for a porting agent

- Work only inside your language's directory. The root, `go/`, `.github/` and other
  languages are someone else's.
- Do not commit. Leave the working tree for the coordinator.
- Run your directory's `check` target before reporting, and report its actual output. If
  the toolchain is missing on this machine, try installing it with `mise` (for example
  `mise use java@temurin-21`); if that fails, say so plainly and report what you could
  verify instead. Never report a test run you did not see pass.
- Report in one screen: what you built, the test count against Go's, anything you could
  not verify, and any place you departed from this brief and why.
