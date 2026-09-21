//! A client for Rails' Action Cable.
//!
//! A [`Client`] owns one WebSocket connection to an Action Cable server and multiplexes any
//! number of channel subscriptions over it. It keeps the connection alive the way the
//! official JavaScript client does: the server beats a ping every three seconds, and a
//! connection that goes quiet for longer than [`ClientBuilder::stale_after`] is torn down
//! and redialed with backoff. Subscriptions survive reconnects; they are resubscribed as
//! soon as the server says welcome.
//!
//! ```no_run
//! use actioncable::{Client, Identifier};
//! use serde_json::json;
//!
//! # async fn run() -> Result<(), actioncable::Error> {
//! let client = Client::builder("wss://example.com/cable").build()?;
//! client.connect().await?;
//!
//! let room = client
//!     .subscribe(Identifier::new("RoomChannel").param("id", 42))
//!     .await?;
//!
//! let reader = room.clone();
//! tokio::spawn(async move {
//!     while let Some(message) = reader.next().await {
//!         println!("{message}");
//!     }
//! });
//!
//! room.perform("speak", json!({ "body": "Hello!" })).await?;
//! room.unsubscribe().await?;
//! client.close().await;
//! # Ok(())
//! # }
//! ```
//!
//! Two things are pluggable. A [`Transport`] carries bytes: the built-in
//! `WebSocketTransport` speaks RFC 6455 over tokio-tungstenite behind the default
//! `websocket` feature, and any other WebSocket library can be dropped in behind the same
//! trait with [`ClientBuilder::transport`]. Without the feature and without a transport,
//! [`ClientBuilder::build`] returns [`Error::NoTransport`]. A [`Protocol`] speaks one Action Cable
//! wire format, negotiated as one WebSocket subprotocol: [`V1Json`] implements
//! `actioncable-v1-json`, and a new format is a new `Protocol` rather than a fork of this
//! client. [`ClientBuilder::protocols`] offers several, and the server picks the one it
//! knows.
//!
//! Where the Go client takes a `context`, this one takes nothing: [`Client::connect`] and
//! [`Client::subscribe`] wait until the server answers or the client stops, and a caller
//! who wants a deadline wraps the call in [`tokio::time::timeout`]. Dropping either future
//! is safe. The client keeps running — [`Client::last_error`] says what it is failing on —
//! and a subscription the server never confirmed is forgotten.
//!
//! A client that stops for good says so through [`Client::done`] and [`Client::err`]: the
//! server hung up and said not to come back, the attempts
//! [`ClientBuilder::max_attempts`] allows ran out, or
//! [`ClientBuilder::stop_on_error`] recognized a failure no reconnect can repair.
//!
//! Where the Go client takes callbacks, this one offers both: a stream of [`Event`]s on
//! every [`Subscription`], and [`SubscribeRequest`] for the callback form on top of the
//! same stream. Headers that expire come from a [`HeaderProvider`], which a closure
//! returning a future satisfies. Nothing here logs through a logger of its own; the
//! client's chatter goes to `tracing`.
//!
//! The `test-support` feature adds `actioncable::test_support`, an in-memory transport a
//! test plays the server on, for testing code built on this client without a network.

mod builder;
mod client;
mod error;
mod identifier;
mod message;
mod protocol;
mod subscription;
#[cfg(feature = "test-support")]
pub mod test_support;
mod transport;
mod v1_json;
#[cfg(feature = "websocket")]
mod websocket;

pub use builder::{ClientBuilder, HeaderProvider};
pub use client::Client;
pub use error::{DisconnectReason, Error};
pub use identifier::Identifier;
pub use message::Message;
pub use protocol::{Command, CommandName, Incoming, Kind, Protocol, SUBPROTOCOL_UNSUPPORTED};
pub use subscription::{Event, SubscribeRequest, Subscription};
pub use transport::{Conn, DialOptions, Transport};
pub use v1_json::{SUBPROTOCOL_V1_JSON, V1Json};
#[cfg(feature = "websocket")]
pub use websocket::WebSocketTransport;

/// Compiles the README's examples as doctests.
#[cfg(all(doctest, feature = "websocket"))]
#[doc = include_str!("../README.md")]
pub struct ReadmeExamples;
