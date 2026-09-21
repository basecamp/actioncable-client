use std::sync::Arc;

use async_trait::async_trait;
use http::HeaderMap;

use crate::error::Error;

/// Dials the network connection a client talks over. It is the seam where a network handler
/// plugs in: the built-in `WebSocketTransport` speaks RFC 6455 over tokio-tungstenite, and
/// wrapping another WebSocket crate, or an in-memory pipe for tests, means implementing
/// this and [`Conn`] and nothing else.
#[async_trait]
pub trait Transport: Send + Sync {
    /// Opens one connection. `options` carries the subprotocols the client's protocols
    /// negotiate under and the headers that authorize the request.
    async fn dial(&self, url: &str, options: DialOptions) -> Result<Box<dyn Conn>, Error>;
}

/// A shared transport dials like the one it shares, so an application can keep one and hand
/// it to every client it builds.
#[async_trait]
impl<T: Transport + ?Sized> Transport for Arc<T> {
    async fn dial(&self, url: &str, options: DialOptions) -> Result<Box<dyn Conn>, Error> {
        (**self).dial(url, options).await
    }
}

/// What the client needs the transport to negotiate: the subprotocols its protocols speak,
/// most preferred first, and the headers that authenticate the request, a cookie or a
/// token, since an Action Cable server authorizes the upgrade request itself.
#[derive(Debug, Clone, Default)]
pub struct DialOptions {
    /// The subprotocols to offer, most preferred first, with
    /// [`SUBPROTOCOL_UNSUPPORTED`](crate::SUBPROTOCOL_UNSUPPORTED) last.
    pub subprotocols: Vec<String>,
    /// The headers the upgrade request carries and nothing else ambient.
    pub headers: HeaderMap,
}

/// One live connection. The client reads from one task and writes from another, one write
/// at a time, and may call [`close`](Conn::close) concurrently with either. Closing has to
/// interrupt a read in flight so the reader learns the connection is gone.
#[async_trait]
pub trait Conn: Send + Sync {
    /// What the server negotiated, `None` if it named nothing.
    fn subprotocol(&self) -> Option<&str>;

    /// The next complete message. Fails once the connection is unusable, including after
    /// `close`.
    async fn read(&self) -> Result<Vec<u8>, Error>;

    /// Sends one text message.
    async fn write(&self, payload: &[u8]) -> Result<(), Error>;

    /// Hangs up, with 1000 Normal Closure where the protocol has a code to send. Safe to
    /// call twice.
    async fn close(&self);

    /// Hangs up with a code and reason of the caller's choosing, for a caller with
    /// something to tell the server. Where the Go client asks whether a connection also
    /// implements `StatusCloser`, a Rust caller can always call this: the default forwards
    /// to [`close`](Conn::close), so a transport whose library can't say why hangs up all
    /// the same. The built-in transport sends the code and as much of the reason as a
    /// control frame has room for.
    async fn close_with_status(&self, code: u16, reason: &str) {
        let _ = (code, reason);
        self.close().await;
    }
}
