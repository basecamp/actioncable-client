//! In-memory connections a test can play the server on, and a made-up protocol that stamps
//! everything it encodes so a test can tell which protocol the client settled on. Behind the
//! `test-support` feature, for this crate's own tests and for the tests of anything built on
//! it.
//!
//! Everything here panics rather than returning an error: a test that can't have what it
//! asked for has nothing left to assert.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a fake for tests says what went wrong by failing the test"
)]

use std::collections::{HashSet, VecDeque};
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;
use tokio::sync::{mpsc, watch};

use crate::error::Error;
use crate::protocol::{Command, Incoming, Protocol};
use crate::transport::{Conn, DialOptions, Transport};
use crate::v1_json::{SUBPROTOCOL_V1_JSON, V1Json};

/// How long a test will hang around for something that should already have happened.
pub const WAIT: Duration = Duration::from_secs(2);

/// How long a test waits to be sure nothing is coming.
const SILENCE: Duration = Duration::from_millis(100);

/// A transport whose connections a test accepts and plays the server on.
#[derive(Clone)]
pub struct FakeTransport {
    shared: Arc<TransportState>,
}

struct TransportState {
    subprotocol: Mutex<Option<String>>,
    write_buffer: Mutex<usize>,
    dialed: mpsc::UnboundedSender<Arc<FakeConn>>,
    accepting: tokio::sync::Mutex<mpsc::UnboundedReceiver<Arc<FakeConn>>>,
    dial_errors: Mutex<VecDeque<String>>,
    options: Mutex<Option<DialOptions>>,
}

impl FakeTransport {
    /// A transport that answers every dial with a connection speaking
    /// `actioncable-v1-json`.
    pub fn new() -> FakeTransport {
        let (dialed, accepting) = mpsc::unbounded_channel();
        FakeTransport {
            shared: Arc::new(TransportState {
                subprotocol: Mutex::new(Some(SUBPROTOCOL_V1_JSON.to_string())),
                write_buffer: Mutex::new(32),
                dialed,
                accepting: tokio::sync::Mutex::new(accepting),
                dial_errors: Mutex::new(VecDeque::new()),
                options: Mutex::new(None),
            }),
        }
    }

    /// What the fake server names as the negotiated subprotocol from now on.
    pub fn speak(&self, subprotocol: Option<&str>) {
        *lock(&self.shared.subprotocol) = subprotocol.map(str::to_string);
    }

    /// How many commands a connection takes before a write waits on the test to read them.
    /// One, the smallest a channel can be, is how a test holds the client mid-write.
    pub fn write_buffer(&self, commands: usize) {
        *lock(&self.shared.write_buffer) = commands.max(1);
    }

    /// Turns the next dial down, as a refused connection would.
    pub fn fail_next_dial(&self, reason: &str) {
        lock(&self.shared.dial_errors).push_back(reason.to_string());
    }

    /// The options the client last dialed with.
    pub fn dialed_with(&self) -> DialOptions {
        lock(&self.shared.options)
            .clone()
            .expect("the client never dialed")
    }

    /// The next connection the client opened, to play the server on.
    pub async fn accept(&self) -> Arc<FakeConn> {
        tokio::time::timeout(WAIT, self.shared.accepting.lock().await.recv())
            .await
            .expect("no connection was dialed")
            .unwrap()
    }

    /// Fails when the client dials at all in the next little while.
    pub async fn refuse_dial(&self) {
        let dialed = tokio::time::timeout(SILENCE, self.shared.accepting.lock().await.recv()).await;
        if let Ok(Some(conn)) = dialed {
            panic!(
                "expected no connection, got one with subprotocol {:?}",
                conn.subprotocol
            );
        }
    }
}

impl Default for FakeTransport {
    fn default() -> FakeTransport {
        FakeTransport::new()
    }
}

#[async_trait]
impl Transport for FakeTransport {
    async fn dial(&self, _url: &str, options: DialOptions) -> Result<Box<dyn Conn>, Error> {
        *lock(&self.shared.options) = Some(options);
        if let Some(reason) = lock(&self.shared.dial_errors).pop_front() {
            return Err(Error::transport(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                reason,
            )));
        }

        let conn = Arc::new(FakeConn::new(
            lock(&self.shared.subprotocol).clone(),
            *lock(&self.shared.write_buffer),
        ));
        self.shared.dialed.send(Arc::clone(&conn)).unwrap();
        Ok(Box::new(ClientEnd(conn)))
    }
}

/// The server's end of one connection. Like Rails it keeps the identifiers it has confirmed
/// and ignores a second subscribe for one of them, so a test reads off the wire exactly what
/// a Rails server would act on, in the order the test acts on it.
pub struct FakeConn {
    subprotocol: Option<String>,
    incoming: mpsc::Sender<Vec<u8>>,
    reading: tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>,
    outgoing: mpsc::Sender<Vec<u8>>,
    sent: tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>,
    /// Counts the writes that have begun, so a test can tell the client is stuck in one
    /// before anyone has read what it wrote.
    writes: watch::Sender<usize>,
    confirmed: Mutex<HashSet<String>>,
    failing_writes: AtomicBool,
    closed: watch::Sender<bool>,
}

impl FakeConn {
    fn new(subprotocol: Option<String>, write_buffer: usize) -> FakeConn {
        let (incoming, reading) = mpsc::channel(1);
        let (outgoing, sent) = mpsc::channel(write_buffer);
        FakeConn {
            subprotocol,
            incoming,
            reading: tokio::sync::Mutex::new(reading),
            outgoing,
            sent: tokio::sync::Mutex::new(sent),
            writes: watch::Sender::new(0),
            confirmed: Mutex::new(HashSet::new()),
            failing_writes: AtomicBool::new(false),
            closed: watch::Sender::new(false),
        }
    }

    /// Plays a server frame to the client.
    pub async fn push(&self, frame: &str) {
        let mut closed = self.closed.subscribe();
        tokio::select! {
            biased;
            _ = closed.wait_for(|closed| *closed) => panic!("connection closed before {frame} could be sent"),
            sent = tokio::time::timeout(WAIT, self.incoming.send(frame.as_bytes().to_vec())) => {
                sent.unwrap_or_else(|_| panic!("client never read {frame}")).unwrap_or_else(|_| panic!("client hung up before reading {frame}"));
            }
        }
    }

    /// Plays the welcome that makes the connection usable.
    pub async fn welcome(&self) {
        self.push(r#"{"type":"welcome"}"#).await;
    }

    /// Confirms a subscription, and remembers it the way Rails does.
    pub async fn confirm(&self, identifier: &str) {
        lock(&self.confirmed).insert(identifier.to_string());
        self.push(&format!(
            r#"{{"type":"confirm_subscription","identifier":{}}}"#,
            quote(identifier)
        ))
        .await;
    }

    /// Turns a subscription down, which also forgets it: the client is free to try again.
    pub async fn reject(&self, identifier: &str) {
        lock(&self.confirmed).remove(identifier);
        self.push(&format!(
            r#"{{"type":"reject_subscription","identifier":{}}}"#,
            quote(identifier)
        ))
        .await;
    }

    /// Plays a channel message to the client, as the server broadcasts one to `identifier`.
    pub async fn broadcast(&self, identifier: &str, message: &str) {
        self.push(&format!(
            r#"{{"identifier":{},"message":{message}}}"#,
            quote(identifier)
        ))
        .await;
    }

    /// Every write from now on fails, the way a socket the peer has stopped reading does
    /// once the write timeout passes.
    pub fn fail_writes(&self) {
        self.failing_writes.store(true, Ordering::SeqCst);
    }

    /// Waits until `count` writes have begun. With a write buffer smaller than that, the
    /// last of them is still waiting for the test to read what came before it.
    pub async fn writing(&self, count: usize) {
        let mut writes = self.writes.subscribe();
        tokio::time::timeout(WAIT, writes.wait_for(|writes| *writes >= count))
            .await
            .expect("the client wrote less than that")
            .unwrap();
    }

    /// The next payload the client wrote that the server acts on, exactly as it went out.
    pub async fn sent(&self) -> Vec<u8> {
        self.next_acted_on(WAIT).await.expect("client sent nothing")
    }

    /// Reads what the client wrote until something Rails would act on: a second subscribe
    /// for an identifier already confirmed is skipped, the way Rails skips it, and an
    /// unsubscribe makes room for the next subscribe.
    async fn next_acted_on(&self, wait: Duration) -> Option<Vec<u8>> {
        let mut sent = self.sent.lock().await;
        loop {
            match tokio::time::timeout(wait, sent.recv()).await {
                Ok(Some(payload)) if self.acts_on(&payload) => break Some(payload),
                Ok(Some(_ignored)) => {}
                Ok(None) | Err(_) => break None,
            }
        }
    }

    fn acts_on(&self, payload: &[u8]) -> bool {
        match serde_json::from_slice::<SentCommand>(payload) {
            Ok(command) if command.command == "subscribe" => {
                !lock(&self.confirmed).contains(&command.identifier)
            }
            Ok(command) if command.command == "unsubscribe" => {
                lock(&self.confirmed).remove(&command.identifier);
                true
            }
            _ => true,
        }
    }

    /// The next command the client sent, decoded.
    pub async fn command(&self) -> SentCommand {
        let payload = self.sent().await;
        serde_json::from_slice(&payload).unwrap_or_else(|error| {
            panic!(
                "decoding command {}: {error}",
                String::from_utf8_lossy(&payload)
            )
        })
    }

    /// The next command, which has to be the one named. Taking a subscribe is not
    /// answering it: until [`confirm`](FakeConn::confirm), the server is as good as having
    /// dropped it on the floor and the client's guarantor will send it again.
    pub async fn expect_command(&self, name: &str, identifier: &str) -> SentCommand {
        let command = self.command().await;
        assert_eq!(
            name, command.command,
            "expected {name} {identifier}, got {command:?}"
        );
        assert_eq!(
            identifier, command.identifier,
            "expected {name} {identifier}, got {command:?}"
        );
        command
    }

    /// Fails when the client sends anything in the next little while.
    pub async fn expect_silence(&self) {
        if let Some(payload) = self.next_acted_on(SILENCE).await {
            panic!(
                "expected no command, got {}",
                String::from_utf8_lossy(&payload)
            );
        }
    }

    /// Hangs up from the server's side.
    pub fn close(&self) {
        self.closed.send_replace(true);
    }
}

struct ClientEnd(Arc<FakeConn>);

#[async_trait]
impl Conn for ClientEnd {
    fn subprotocol(&self) -> Option<&str> {
        self.0.subprotocol.as_deref()
    }

    async fn read(&self) -> Result<Vec<u8>, Error> {
        let mut closed = self.0.closed.subscribe();
        let mut reading = self.0.reading.lock().await;
        tokio::select! {
            biased;
            _ = closed.wait_for(|closed| *closed) => Err(eof()),
            payload = reading.recv() => payload.ok_or_else(eof),
        }
    }

    async fn write(&self, payload: &[u8]) -> Result<(), Error> {
        if self.0.failing_writes.load(Ordering::SeqCst) {
            return Err(Error::transport(io::Error::new(
                io::ErrorKind::TimedOut,
                "the peer stopped reading",
            )));
        }
        self.0.writes.send_modify(|writes| *writes += 1);

        let mut closed = self.0.closed.subscribe();
        tokio::select! {
            biased;
            _ = closed.wait_for(|closed| *closed) => Err(eof()),
            sent = self.0.outgoing.send(payload.to_vec()) => sent.map_err(|_| eof()),
        }
    }

    async fn close(&self) {
        self.0.close();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn eof() -> Error {
    Error::transport(io::Error::new(
        io::ErrorKind::UnexpectedEof,
        "connection closed",
    ))
}

/// A command as the client wrote it.
#[derive(Debug, Deserialize)]
pub struct SentCommand {
    /// The verb: `subscribe`, `unsubscribe` or `message`.
    pub command: String,
    /// The identifier it is about.
    pub identifier: String,
    /// The payload, on a `message`.
    pub data: Option<String>,
}

/// `value` as a JSON string literal, for building frames by hand.
pub fn quote(value: &str) -> String {
    serde_json::to_string(value).unwrap()
}

/// Speaks a made-up subprotocol and stamps everything it encodes, so a test can tell which
/// protocol the client settled on.
pub struct FakeProtocol {
    /// The subprotocol it negotiates under.
    pub subprotocol: String,
    /// What it puts in front of every payload.
    pub stamp: String,
}

impl FakeProtocol {
    /// A stand-in for a second protocol version, `actioncable-v2-json`.
    pub fn v2() -> FakeProtocol {
        FakeProtocol {
            subprotocol: "actioncable-v2-json".to_string(),
            stamp: "v2:".to_string(),
        }
    }
}

impl Protocol for FakeProtocol {
    fn subprotocol(&self) -> &str {
        &self.subprotocol
    }

    fn encode(&self, command: &Command) -> Result<Vec<u8>, Error> {
        let mut payload = self.stamp.as_bytes().to_vec();
        payload.extend(V1Json.encode(command)?);
        Ok(payload)
    }

    fn decode(&self, payload: &[u8]) -> Result<Incoming, Error> {
        V1Json.decode(
            payload
                .strip_prefix(self.stamp.as_bytes())
                .unwrap_or(payload),
        )
    }
}
