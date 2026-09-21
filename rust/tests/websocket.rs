//! The built-in transport against a loopback server that does the RFC 6455 upgrade by
//! hand, so what is under test is this crate's framing and not a library's idea of it.

#![cfg(all(feature = "websocket", feature = "test-support"))]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]

mod support;

use std::time::Duration;

use actioncable::test_support::{WAIT, quote};
use actioncable::{Client, Conn, Error, SUBPROTOCOL_V1_JSON};
use http::{HeaderMap, HeaderValue};
use support::peer::{OP_BINARY, OP_CLOSE, OP_CONTINUATION, OP_PING, OP_PONG, OP_TEXT, TestServer};
use support::{room, within};

#[tokio::test]
async fn the_transport_negotiates_the_subprotocol() {
    let server = TestServer::start().await;

    let conn = server
        .dial(offering(&[SUBPROTOCOL_V1_JSON]), HeaderMap::new())
        .await;
    let peer = server.accept().await;

    assert_eq!(Some(SUBPROTOCOL_V1_JSON), conn.subprotocol());
    assert_eq!(
        "actioncable-v1-json, actioncable-unsupported",
        peer.header("sec-websocket-protocol"),
        "expected the client to offer the subprotocol and the sentinel"
    );
}

#[tokio::test]
async fn the_transport_sends_the_headers_it_was_handed() {
    let server = TestServer::start().await;
    let mut headers = HeaderMap::new();
    headers.insert("cookie", HeaderValue::from_static("session=secret"));
    headers.insert("origin", HeaderValue::from_static("https://example.com"));

    let _conn = server.dial(offering(&[SUBPROTOCOL_V1_JSON]), headers).await;
    let peer = server.accept().await;

    assert_eq!("session=secret", peer.header("cookie"));
    assert_eq!("https://example.com", peer.header("origin"));
    assert_eq!(
        concat!("actioncable/", env!("CARGO_PKG_VERSION")),
        peer.header("user-agent")
    );
    assert_eq!("/cable", peer.path);
}

#[tokio::test]
async fn the_callers_user_agent_wins() {
    let server = TestServer::start().await;
    let mut headers = HeaderMap::new();
    headers.insert("user-agent", HeaderValue::from_static("custom-agent"));

    let _conn = server.dial(vec![], headers).await;

    assert_eq!("custom-agent", server.accept().await.header("user-agent"));
}

#[tokio::test]
async fn messages_round_trip() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    conn.write(br#"{"command":"subscribe"}"#).await.unwrap();
    assert_eq!(r#"{"command":"subscribe"}"#, peer.read_text().await);

    peer.write(OP_TEXT, br#"{"type":"welcome"}"#).await;
    assert_eq!(r#"{"type":"welcome"}"#, read(&*conn).await);

    peer.write(OP_BINARY, b"binary too").await;
    assert_eq!("binary too", read(&*conn).await);
}

#[tokio::test]
async fn large_messages_round_trip() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    let long = "cable".repeat(30_000);
    peer.write(OP_TEXT, long.as_bytes()).await;
    assert_eq!(long, read(&*conn).await);

    conn.write(long.as_bytes()).await.unwrap();
    assert_eq!(long, peer.read_text().await);
}

#[tokio::test]
async fn pings_are_answered_and_skipped() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    peer.write(OP_PING, b"beat").await;
    peer.write(OP_TEXT, b"after the ping").await;

    assert_eq!("after the ping", read(&*conn).await);

    let (opcode, payload) = peer.read_frame().await;
    assert_eq!(OP_PONG, opcode, "expected a pong");
    assert_eq!(
        b"beat".to_vec(),
        payload,
        "expected the ping's payload back"
    );
}

#[tokio::test]
async fn fragments_are_reassembled() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    peer.write_fragment(OP_TEXT, b"one ", false).await;
    peer.write_fragment(OP_PING, b"interleaved", true).await;
    peer.write_fragment(OP_CONTINUATION, b"message", true).await;

    assert_eq!("one message", read(&*conn).await);
}

#[tokio::test]
async fn oversized_messages_are_refused() {
    let server = TestServer::start().await;
    let conn = server
        .dial_with(|transport| transport.max_message_size(8))
        .await;
    let mut peer = server.accept().await;

    peer.write(OP_TEXT, b"far too long for eight bytes").await;

    assert!(
        matches!(
            read_within(&*conn).await,
            Err(Error::MessageTooBig { limit: 8, .. })
        ),
        "expected the message to be refused against the limit"
    );
}

#[tokio::test]
async fn oversized_fragmented_messages_are_refused() {
    let server = TestServer::start().await;
    let conn = server
        .dial_with(|transport| transport.max_message_size(8))
        .await;
    let mut peer = server.accept().await;

    peer.write_fragment(OP_TEXT, b"five ", false).await;
    peer.write_fragment(OP_CONTINUATION, b"more", true).await;

    assert!(
        matches!(
            read_within(&*conn).await,
            Err(Error::MessageTooBig { limit: 8, .. })
        ),
        "expected the reassembled message to be refused against the limit"
    );
}

#[tokio::test]
async fn a_server_close_is_reported_with_its_code_and_reason() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    let mut frame = 4401_u16.to_be_bytes().to_vec();
    frame.extend_from_slice(b"unauthorized");
    peer.write(OP_CLOSE, &frame).await;

    assert!(
        matches!(
            read_within(&*conn).await,
            Err(Error::Close { code: 4401, reason }) if reason == "unauthorized"
        ),
        "expected the close frame the server sent"
    );
}

#[tokio::test]
async fn a_server_close_without_a_status_is_reported_as_1005() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    peer.write(OP_CLOSE, b"").await;

    assert!(
        matches!(
            read_within(&*conn).await,
            Err(Error::Close { code: 1005, reason }) if reason.is_empty()
        ),
        "expected the code that stands in for a close frame carrying none"
    );
}

#[tokio::test]
async fn closing_with_a_status_says_so_on_the_wire() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    conn.close_with_status(4000, "done here").await;

    let (opcode, payload) = peer.read_frame().await;
    assert_eq!(OP_CLOSE, opcode);
    assert_eq!(4000, u16::from_be_bytes([payload[0], payload[1]]));
    assert_eq!("done here", String::from_utf8_lossy(&payload[2..]));
}

#[tokio::test]
async fn a_close_reason_is_truncated_to_fit_the_frame() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    conn.close_with_status(4000, &"r".repeat(200)).await;

    let (opcode, payload) = peer.read_frame().await;
    assert_eq!(OP_CLOSE, opcode);
    assert_eq!(
        125,
        payload.len(),
        "a control frame's payload is at most 125 bytes"
    );
}

#[tokio::test]
async fn a_server_that_will_not_upgrade_fails_the_dial() {
    let server = TestServer::answering("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;

    let refused = server.try_dial().await.unwrap_err();

    assert!(
        matches!(&refused, Error::Handshake { status } if status.as_u16() == 404),
        "expected a handshake error, got {refused}"
    );
    assert_eq!(
        "server refused the upgrade with 404 Not Found",
        refused.to_string()
    );
}

#[tokio::test]
async fn a_redirect_is_not_followed() {
    let server = TestServer::answering(
        "HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n",
    )
    .await;

    let refused = server.try_dial().await.unwrap_err();

    assert!(
        matches!(&refused, Error::Handshake { status } if status.as_u16() == 302),
        "expected the redirect to be reported rather than followed, got {refused}"
    );
}

#[tokio::test]
async fn a_bad_accept_key_fails_the_dial() {
    let server = TestServer::with_a_bad_accept_key().await;

    let refused = server.try_dial().await.unwrap_err();

    assert!(
        matches!(refused, Error::Transport(_)),
        "expected a bad Sec-WebSocket-Accept to fail the dial"
    );
}

#[tokio::test]
async fn a_masked_server_frame_fails_the_connection() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    // RFC 6455 §5.1: a server must never mask, and a client that sees a masked frame must
    // fail the connection rather than quietly unmask it.
    peer.write_masked(OP_TEXT, br#"{"type":"welcome"}"#).await;

    let outcome = read_within(&*conn).await;
    assert!(
        outcome.is_err(),
        "expected a masked frame to fail the connection, got {outcome:?}"
    );
}

#[tokio::test]
async fn a_close_is_answered_once() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let mut peer = server.accept().await;

    peer.write(OP_CLOSE, &1000_u16.to_be_bytes()).await;
    assert!(read_within(&*conn).await.is_err());
    conn.close().await;

    assert_eq!(
        1,
        peer.close_frames().await,
        "expected exactly one close frame in reply"
    );
}

/// The Go client bounds a read with the context it is handed; here the caller wraps the
/// read in a timeout, and `close` is what interrupts one already waiting.
#[tokio::test]
async fn a_read_gives_up_with_its_timeout() {
    let server = TestServer::start().await;
    let conn = server.dial(vec![], HeaderMap::new()).await;
    let _peer = server.accept().await;

    let reading = tokio::time::timeout(Duration::from_millis(50), conn.read()).await;

    assert!(reading.is_err(), "expected the read to still be waiting");
}

#[tokio::test]
async fn closing_interrupts_a_pending_read() {
    let server = TestServer::start().await;
    let conn: std::sync::Arc<dyn Conn> = server.dial(vec![], HeaderMap::new()).await.into();
    let _peer = server.accept().await;

    let reader = std::sync::Arc::clone(&conn);
    let reading = tokio::spawn(async move { reader.read().await });
    tokio::time::sleep(Duration::from_millis(50)).await;
    conn.close().await;

    let outcome = within(reading).await.unwrap();
    assert!(
        outcome.is_err(),
        "expected the read to end, got {outcome:?}"
    );
}

/// The whole cable dance over an actual WebSocket connection.
#[tokio::test]
async fn the_client_runs_over_the_real_transport() {
    let server = TestServer::start().await;
    let client = Client::builder(server.url()).build().unwrap();
    let key = room().key();

    let connecting = tokio::spawn({
        let client = client.clone();
        async move { client.connect().await }
    });
    let mut peer = server.accept().await;
    peer.write(OP_TEXT, br#"{"type":"welcome"}"#).await;
    within(connecting).await.unwrap().unwrap();

    let subscribing = tokio::spawn({
        let client = client.clone();
        async move { client.subscribe(room()).await }
    });
    assert_eq!(
        format!(r#"{{"command":"subscribe","identifier":{}}}"#, quote(&key)),
        peer.read_text().await
    );
    peer.write(
        OP_TEXT,
        format!(
            r#"{{"type":"confirm_subscription","identifier":{}}}"#,
            quote(&key)
        )
        .as_bytes(),
    )
    .await;
    let subscription = within(subscribing).await.unwrap().unwrap();

    peer.write(
        OP_TEXT,
        format!(
            r#"{{"identifier":{},"message":{{"body":"Hello!"}}}}"#,
            quote(&key)
        )
        .as_bytes(),
    )
    .await;
    assert_eq!(
        r#"{"body":"Hello!"}"#,
        within(subscription.next()).await.unwrap().as_str()
    );

    subscription
        .perform("speak", serde_json::json!({ "body": "Hi!" }))
        .await
        .unwrap();
    assert_eq!(
        format!(
            r#"{{"command":"message","identifier":{},"data":"{{\"action\":\"speak\",\"body\":\"Hi!\"}}"}}"#,
            quote(&key)
        ),
        peer.read_text().await
    );

    client.close().await;
    assert!(within(subscription.next()).await.is_none());
}

fn offering(subprotocols: &[&str]) -> Vec<String> {
    let mut offered: Vec<String> = subprotocols
        .iter()
        .map(|name| (*name).to_string())
        .collect();
    offered.push(actioncable::SUBPROTOCOL_UNSUPPORTED.to_string());
    offered
}

async fn read(conn: &dyn Conn) -> String {
    String::from_utf8(read_within(conn).await.unwrap()).unwrap()
}

async fn read_within(conn: &dyn Conn) -> Result<Vec<u8>, Error> {
    tokio::time::timeout(WAIT, conn.read())
        .await
        .expect("the read should already have finished")
}
