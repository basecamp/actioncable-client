# actioncable-client

One client for Rails' [Action Cable](https://guides.rubyonrails.org/action_cable_overview.html)
per language Basecamp ships in. Each is a complete, independently buildable
package with a README of its own, and each is the Go client in another
language: the same behavior, in the idiom a reader of that language expects.

A client owns one connection and multiplexes subscriptions over it. It waits
for the welcome, resubscribes after every reconnect, resends subscribes that
were never confirmed, treats a quiet connection as dead, and backs off with
jitter — so a caller subscribes once and keeps getting messages.

Two of its three pieces are pluggable. The **transport** carries bytes and
ships as an RFC 6455 WebSocket written on the platform's own sockets, so no
client here has a runtime dependency for it. The **protocol** speaks one wire
format under one subprotocol name, and `actioncable-v1-json` — Rails' own — is
what you get unless you pass another. Swap either for a fake and the whole
client runs in a test with no network at all.


## The clients

| Language                        | Package                                       | Install                                                        |
|---------------------------------|-----------------------------------------------|----------------------------------------------------------------|
| [Go](go/README.md)              | `github.com/basecamp/actioncable-client/go`   | `go get github.com/basecamp/actioncable-client/go`             |
| [TypeScript](typescript/README.md) | `@37signals/actioncable`                   | `npm install @37signals/actioncable`                           |
| [Python](python/README.md)      | `actioncable-client`, import `actioncable`    | `pip install actioncable-client`                               |
| [Ruby](ruby/README.md)          | `actioncable-client`, require `actioncable_client` | `bundle add actioncable-client`                           |
| [Kotlin](kotlin/README.md)      | `com.basecamp:actioncable-client`             | `implementation("com.basecamp:actioncable-client:VERSION")`    |
| [Rust](rust/README.md)          | crate `actioncable-client`, lib `actioncable` | `cargo add actioncable-client`                                 |
| [Swift](swift/README.md)        | SwiftPM `ActionCable`                         | `.package(url: "https://github.com/basecamp/actioncable-client", from: "VERSION")` |

The Ruby names steer clear of Rails' own `ActionCable` constant and
`action_cable` require path on purpose: a gem that defined `ActionCable::Client`
would be reaching into Rails' namespace.

One version number covers all seven, and every
[release](https://github.com/basecamp/actioncable-client/releases) carries the
install line for each with that version filled in. The Kotlin package goes to
GitHub Packages, which wants a repository and a token —
[its README](kotlin/README.md#installation) has the four lines.


## Working on it

Every language directory carries its own `Makefile` — Kotlin its Gradle tasks —
with the same targets, and the root Makefile runs them:

```bash
make check              # every language
make ruby-check         # just one: go, typescript, python, ruby, kotlin, rust, swift
```

Where to look next:

- [PORTING.md](PORTING.md) — what a port is, and the behavior every one of them
  owes the Go client. Read it before writing a new one or changing what the
  clients do.
- [CONTRIBUTING.md](CONTRIBUTING.md) — discussions come before issues and pull
  requests.
- [RELEASING.md](RELEASING.md) — one version, one tag, seven registries.
- [AGENTS.md](AGENTS.md) — the short version for an agent arriving here.


## License

Released under the MIT License. See [LICENSE](LICENSE).
