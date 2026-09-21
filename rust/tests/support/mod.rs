//! What the test binaries share: a client wired to the in-memory fake, the waits that keep
//! a stuck test from hanging, and the loopback server in [`peer`].

#![allow(
    dead_code,
    unreachable_pub,
    reason = "each test binary uses the part of this module its own subject needs"
)]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use actioncable::test_support::{FakeConn, FakeTransport, WAIT};
use actioncable::{
    Client, ClientBuilder, Error, Event, HeaderProvider, Identifier, Message, Subscription,
};
use async_trait::async_trait;
use http::{HeaderMap, HeaderValue};
use serde::Deserialize;
use tokio::task::JoinHandle;

#[cfg(feature = "websocket")]
pub mod peer;

/// The identifier the tests subscribe to, as the server knows it.
pub const ROOM: &str = r#"{"channel":"RoomChannel","id":42}"#;

/// The channel the tests subscribe to.
pub fn room() -> Identifier {
    Identifier::new("RoomChannel").param("id", 42)
}

/// A client on the fake, at a URL nothing resolves.
pub fn builder(transport: &FakeTransport) -> ClientBuilder {
    Client::builder("ws://cable.example.com/cable").transport(transport.clone())
}

/// Backs off in a millisecond, so a test that wants a redial doesn't wait a second for it.
pub fn quick_backoff(builder: ClientBuilder) -> ClientBuilder {
    builder.backoff(Duration::from_millis(1), Duration::from_millis(1))
}

/// Connects in the background, since `connect` waits for the welcome the test still has to
/// send.
pub fn connect(client: &Client) -> JoinHandle<Result<(), Error>> {
    let client = client.clone();
    tokio::spawn(async move { client.connect().await })
}

/// Connects a client and plays the server's welcome, returning the connection the test can
/// go on talking over.
pub async fn welcomed(client: &Client, transport: &FakeTransport) -> Arc<FakeConn> {
    let connecting = connect(client);
    let conn = transport.accept().await;
    conn.welcome().await;
    within(connecting).await.unwrap().unwrap();
    conn
}

/// Subscribes in the background, since `subscribe` waits for the confirmation the test
/// still has to send.
pub fn subscribe(
    client: &Client,
    identifier: Identifier,
) -> JoinHandle<Result<Subscription, Error>> {
    let client = client.clone();
    tokio::spawn(async move { client.subscribe(identifier).await })
}

/// Subscribes to [`room`] and confirms it.
pub async fn subscribed(client: &Client, conn: &FakeConn) -> Subscription {
    let subscribing = subscribe(client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    within(subscribing).await.unwrap().unwrap()
}

/// The next message, which has to arrive.
pub async fn receive(subscription: &Subscription) -> Message {
    within(subscription.next())
        .await
        .expect("the message stream ended")
}

/// The next connection event, which has to arrive.
pub async fn next_event(subscription: &Subscription) -> Event {
    within(subscription.next_event())
        .await
        .expect("the event stream ended")
}

/// Waits for something that should already have happened.
pub async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(WAIT, future)
        .await
        .expect("it should already have happened")
}

/// Waits for the client to stop, which it should already have done.
pub async fn stopped(client: &Client) {
    within(client.done()).await;
}

/// What the tests' channel broadcasts.
#[derive(Deserialize)]
pub struct Said {
    pub body: String,
}

/// An application error a header provider hands back, for the tests about giving up on one.
#[derive(Debug, thiserror::Error)]
#[error("sign in again")]
pub struct SignedOut;

/// Whether `error` is, or wraps, a [`SignedOut`].
pub fn signed_out(error: &Error) -> bool {
    error
        .cause()
        .is_some_and(<dyn std::error::Error + Send + Sync>::is::<SignedOut>)
}

/// What the operating system called the failure underneath `error`, for recognizing a
/// refused dial or a connection that went away.
pub fn io_kind(error: &Error) -> Option<std::io::ErrorKind> {
    error
        .cause()
        .and_then(<dyn std::error::Error + Send + Sync>::downcast_ref::<std::io::Error>)
        .map(std::io::Error::kind)
}

/// Hands out a fresh bearer token on every ask, and turns the first `failures` asks down.
pub struct Bearer {
    asked: AtomicU64,
    failures: u64,
    refusal: Refusal,
}

/// What a refused ask hands back.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Something another dial might get past.
    Temporary,
    /// Something no dial will.
    SignedOut,
}

impl Bearer {
    /// Refuses the first `failures` asks with something a later dial might get past.
    pub fn new(failures: u64) -> Bearer {
        Bearer {
            asked: AtomicU64::new(0),
            failures,
            refusal: Refusal::Temporary,
        }
    }

    /// Refuses everything after the first `works` asks, for good.
    pub fn signing_out_after(works: u64) -> Bearer {
        Bearer {
            asked: AtomicU64::new(0),
            failures: works,
            refusal: Refusal::SignedOut,
        }
    }

    /// How many times it has been asked.
    pub fn asked(&self) -> u64 {
        self.asked.load(Ordering::SeqCst)
    }

    fn refuses(&self, asked: u64) -> bool {
        match self.refusal {
            Refusal::Temporary => asked <= self.failures,
            Refusal::SignedOut => asked > self.failures,
        }
    }
}

#[async_trait]
impl HeaderProvider for Bearer {
    async fn headers(&self) -> Result<HeaderMap, Error> {
        let asked = self.asked.fetch_add(1, Ordering::SeqCst) + 1;
        if self.refuses(asked) {
            match self.refusal {
                Refusal::Temporary => Err(Error::headers(std::io::Error::other(
                    "no credentials to hand over",
                ))),
                Refusal::SignedOut => Err(Error::headers(SignedOut)),
            }
        } else {
            let mut headers = HeaderMap::new();
            headers.insert(
                "authorization",
                HeaderValue::from_str(&format!("Bearer token-{asked}")).unwrap(),
            );
            Ok(headers)
        }
    }
}
