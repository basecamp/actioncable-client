use std::io;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use http::HeaderValue;
use http::header::{SEC_WEBSOCKET_EXTENSIONS, SEC_WEBSOCKET_PROTOCOL, USER_AGENT};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::watch;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::error::{CapacityError, Error as TungsteniteError};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::protocol::frame::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Message as Frame, client::IntoClientRequest};

use crate::error::Error;
use crate::transport::{Conn, DialOptions, Transport};

const USER_AGENT_VALUE: &str = concat!("actioncable/", env!("CARGO_PKG_VERSION"));
const CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

/// RFC 6455 §7.4.1's code that stands in for a close frame carrying none.
const CLOSE_NO_STATUS: u16 = 1005;

/// What fits in a close frame after the code: a control frame's payload is at most 125
/// bytes.
const MAX_CLOSE_REASON_BYTES: usize = 123;

/// The built-in transport: tokio-tungstenite over rustls, trusting the platform's root
/// certificates. It handles the upgrade handshake, answers pings, and reassembles
/// fragmented messages. The request carries `User-Agent: actioncable/<version>` unless the
/// caller set one, and never negotiates extensions.
#[derive(Debug, Clone)]
pub struct WebSocketTransport {
    handshake_timeout: Duration,
    write_timeout: Duration,
    max_message_size: usize,
}

impl WebSocketTransport {
    /// The transport with its defaults: a ten second handshake, a ten second write, and
    /// messages up to 8 MiB.
    pub fn new() -> WebSocketTransport {
        WebSocketTransport {
            handshake_timeout: Duration::from_secs(10),
            write_timeout: Duration::from_secs(10),
            max_message_size: 8 << 20,
        }
    }

    /// Bounds the TCP connect, the TLS handshake and the upgrade together. Ten seconds by
    /// default.
    pub fn handshake_timeout(mut self, timeout: Duration) -> WebSocketTransport {
        self.handshake_timeout = timeout;
        self
    }

    /// Bounds one write. A peer that has stopped reading would otherwise hold a `perform`
    /// forever; past the timeout the write fails and the connection is dropped and redialed,
    /// the same as a failed read. Ten seconds by default.
    pub fn write_timeout(mut self, timeout: Duration) -> WebSocketTransport {
        self.write_timeout = timeout;
        self
    }

    /// The largest message accepted, in bytes. 8 MiB by default.
    pub fn max_message_size(mut self, bytes: usize) -> WebSocketTransport {
        self.max_message_size = bytes;
        self
    }
}

impl Default for WebSocketTransport {
    fn default() -> WebSocketTransport {
        WebSocketTransport::new()
    }
}

#[async_trait]
impl Transport for WebSocketTransport {
    async fn dial(&self, url: &str, options: DialOptions) -> Result<Box<dyn Conn>, Error> {
        let request = upgrade_request(url, options)?;
        // The frame limit matches the message limit, so an oversized frame is refused by
        // its header, before any of it is read in, the way the Go client refuses one.
        let config = WebSocketConfig::default()
            .max_message_size(Some(self.max_message_size))
            .max_frame_size(Some(self.max_message_size));
        let connecting = tokio_tungstenite::connect_async_with_config(request, Some(config), false);

        let (stream, response) =
            match tokio::time::timeout(self.handshake_timeout, connecting).await {
                Ok(connected) => connected.map_err(failure),
                Err(elapsed) => Err(Error::transport(elapsed)),
            }?;

        let subprotocol = response
            .headers()
            .get(SEC_WEBSOCKET_PROTOCOL)
            .map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned());

        Ok(Box::new(WebSocketConn::new(
            stream,
            subprotocol,
            self.write_timeout,
        )))
    }
}

/// The caller's headers under the ones the handshake needs, so nothing given to the builder
/// can break the upgrade itself. Extensions are never negotiated.
fn upgrade_request(url: &str, options: DialOptions) -> Result<http::Request<()>, Error> {
    let mut request = url.into_client_request().map_err(Error::transport)?;
    let required = request.headers().clone();

    let headers = request.headers_mut();
    headers.extend(options.headers);
    if !headers.contains_key(USER_AGENT) {
        headers.insert(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE));
    }
    headers.remove(SEC_WEBSOCKET_EXTENSIONS);
    headers.remove(SEC_WEBSOCKET_PROTOCOL);
    if !options.subprotocols.is_empty() {
        let offered = options.subprotocols.join(", ");
        headers.insert(
            SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_str(&offered).map_err(Error::transport)?,
        );
    }
    headers.extend(required);

    Ok(request)
}

/// One upgraded socket, split so the client can read on one task and write on another. It
/// is generic over the byte stream only so a test can hand it a pipe with a peer that
/// never reads; a dial always puts a TCP or TLS stream in it.
struct WebSocketConn<S> {
    subprotocol: Option<String>,
    write_timeout: Duration,
    sink: tokio::sync::Mutex<SplitSink<WebSocketStream<S>, Frame>>,
    stream: tokio::sync::Mutex<SplitStream<WebSocketStream<S>>>,
    closed: watch::Sender<bool>,
}

impl<S> WebSocketConn<S>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    fn new(
        socket: WebSocketStream<S>,
        subprotocol: Option<String>,
        write_timeout: Duration,
    ) -> WebSocketConn<S> {
        let (sink, stream) = socket.split();
        WebSocketConn {
            subprotocol,
            write_timeout,
            sink: tokio::sync::Mutex::new(sink),
            stream: tokio::sync::Mutex::new(stream),
            closed: watch::Sender::new(false),
        }
    }

    /// Sends one close frame and interrupts a read in flight. A peer that won't take the
    /// frame within a second is left behind: the socket goes when the connection is
    /// dropped.
    async fn hang_up(&self, frame: Option<CloseFrame>) {
        if self.closed.send_replace(true) {
            return;
        }

        let closing = async {
            let mut sink = self.sink.lock().await;
            let _sent = sink.send(Frame::Close(frame)).await;
            sink.close().await
        };
        if let Err(error) = tokio::time::timeout(CLOSE_TIMEOUT, closing).await {
            tracing::debug!(%error, "the close frame did not go out");
        }
    }
}

#[async_trait]
impl<S> Conn for WebSocketConn<S>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    fn subprotocol(&self) -> Option<&str> {
        self.subprotocol.as_deref()
    }

    /// Pings are answered by tungstenite itself; they and the pongs only need skipping.
    async fn read(&self) -> Result<Vec<u8>, Error> {
        let mut closed = self.closed.subscribe();
        let mut stream = self.stream.lock().await;

        loop {
            let next = tokio::select! {
                biased;
                _ = closed.wait_for(|closed| *closed) => None,
                next = stream.next() => next,
            };

            match next {
                Some(Ok(Frame::Text(text))) => break Ok(Vec::from(text.as_str())),
                Some(Ok(Frame::Binary(bytes))) => break Ok(bytes.to_vec()),
                Some(Ok(Frame::Ping(_) | Frame::Pong(_) | Frame::Frame(_))) => {}
                Some(Ok(Frame::Close(frame))) => break Err(server_closed(frame.as_ref())),
                Some(Err(error)) => break Err(failure(error)),
                None => {
                    break Err(Error::transport(io::Error::new(
                        io::ErrorKind::NotConnected,
                        "the connection is closed",
                    )));
                }
            }
        }
    }

    /// A write the peer won't take within `write_timeout` fails, and a write cut off partway
    /// leaves the socket unusable, so the client hangs up after either.
    async fn write(&self, payload: &[u8]) -> Result<(), Error> {
        let text = String::from_utf8(payload.to_vec()).map_err(Error::transport)?;
        let sending = async { self.sink.lock().await.send(Frame::text(text)).await };
        match tokio::time::timeout(self.write_timeout, sending).await {
            Ok(sent) => sent.map_err(failure),
            Err(elapsed) => Err(Error::transport(elapsed)),
        }
    }

    /// Hangs up with 1000 Normal Closure.
    async fn close(&self) {
        self.hang_up(Some(CloseFrame {
            code: CloseCode::Normal,
            reason: String::new().into(),
        }))
        .await;
    }

    /// Hangs up with the code and reason given, and as much of the reason as a control
    /// frame has room for.
    async fn close_with_status(&self, code: u16, reason: &str) {
        self.hang_up(Some(CloseFrame {
            code: CloseCode::from(code),
            reason: truncate(reason, MAX_CLOSE_REASON_BYTES).into(),
        }))
        .await;
    }
}

/// What the server said when it closed the connection: the code the frame carried, 1005
/// when it carried none, and the text after it.
fn server_closed(frame: Option<&CloseFrame>) -> Error {
    match frame {
        Some(frame) => Error::Close {
            code: u16::from(frame.code),
            reason: frame.reason.to_string(),
        },
        None => Error::Close {
            code: CLOSE_NO_STATUS,
            reason: String::new(),
        },
    }
}

/// The two failures a caller may want to act on rather than read — an upgrade the server
/// refused and a message past the limit, which tungstenite refuses by its header before
/// reading it in — and everything else as the transport error it is.
fn failure(error: TungsteniteError) -> Error {
    match error {
        TungsteniteError::Http(response) => Error::Handshake {
            status: response.status(),
        },
        TungsteniteError::Capacity(CapacityError::MessageTooLong { size, max_size }) => {
            Error::MessageTooBig {
                size,
                limit: max_size,
            }
        }
        other => Error::transport(other),
    }
}

/// As much of `text` as fits in `bytes`, cut on a character boundary.
fn truncate(text: &str, bytes: usize) -> &str {
    if text.len() <= bytes {
        text
    } else {
        let mut end = bytes;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        &text[..end]
    }
}

/// The transport is driven over a real socket by `tests/websocket.rs`. What is left here is
/// what needs the inside of it: a stream with a peer that never reads, and the arithmetic
/// around a close frame.
#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use std::time::Instant;

    use tokio_tungstenite::tungstenite::protocol::Role;

    use super::*;

    #[tokio::test]
    async fn a_write_the_peer_never_reads_times_out() {
        let (ours, _theirs) = tokio::io::duplex(64);
        let socket = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let conn = WebSocketConn::new(socket, None, Duration::from_millis(100));
        let started = Instant::now();

        let outcome = conn.write("cable".repeat(1_000).as_bytes()).await;

        assert!(matches!(outcome, Err(Error::Transport(_))), "{outcome:?}");
        assert!(started.elapsed() >= Duration::from_millis(100));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the write hung past its timeout"
        );
    }

    #[test]
    fn a_close_reason_is_cut_to_what_the_frame_holds() {
        assert_eq!("done here", truncate("done here", MAX_CLOSE_REASON_BYTES));
        assert_eq!(
            MAX_CLOSE_REASON_BYTES,
            truncate(&"r".repeat(200), MAX_CLOSE_REASON_BYTES).len()
        );
        assert_eq!("ab", truncate("abçd", 3), "a cut lands on a character");
    }
}
