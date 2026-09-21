use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use http::header::{COOKIE, ORIGIN};
use http::{HeaderMap, HeaderName, HeaderValue};
use url::Url;

use crate::client::Client;
use crate::error::Error;
use crate::protocol::Protocol;
use crate::transport::Transport;
use crate::v1_json::V1Json;

/// Builds the headers for a dial, asked on every dial rather than once. A client reconnects
/// on its own for as long as it runs, which is longer than a credential that expires lives,
/// and a reconnect carrying the token the first dial used would be turned down for good.
///
/// What it returns is laid over the headers already set on the builder, so an `Origin` or a
/// token given with [`ClientBuilder::header`] survives. An error turns down that dial, and
/// the client tries again on its backoff.
///
/// Any `Fn() -> Future<Output = Result<HeaderMap, Error>>` is a provider, so the quick form
/// is a closure:
///
/// ```no_run
/// use actioncable::{Client, Error};
/// use http::{HeaderMap, HeaderValue};
///
/// # fn build() -> Result<Client, Error> {
/// let client = Client::builder("wss://example.com/cable")
///     .header_provider(|| async {
///         let mut headers = HeaderMap::new();
///         headers.insert("Authorization", HeaderValue::from_static("Bearer token"));
///         Ok(headers)
///     })
///     .build()?;
/// # Ok(client)
/// # }
/// ```
///
/// A credentials type that already knows how to refresh itself implements the trait
/// directly.
#[async_trait]
pub trait HeaderProvider: Send + Sync {
    /// The headers for the dial about to happen, or [`Error::headers`] wrapping whatever
    /// stopped them from being built.
    async fn headers(&self) -> Result<HeaderMap, Error>;
}

#[async_trait]
impl<F, Fut> HeaderProvider for F
where
    F: Fn() -> Fut + Send + Sync,
    Fut: Future<Output = Result<HeaderMap, Error>> + Send,
{
    async fn headers(&self) -> Result<HeaderMap, Error> {
        self().await
    }
}

/// A shared provider answers like the one it shares, so an application can keep one — and
/// the credentials behind it — and hand it to every client it builds.
#[async_trait]
impl<T: HeaderProvider + ?Sized> HeaderProvider for Arc<T> {
    async fn headers(&self) -> Result<HeaderMap, Error> {
        (**self).headers().await
    }
}

/// Recognizes the connection errors that retrying cannot repair. See
/// [`ClientBuilder::stop_on_error`].
type Terminal = Arc<dyn Fn(&Error) -> bool + Send + Sync>;

/// Configures a [`Client`]. Nothing touches the network until [`Client::connect`].
pub struct ClientBuilder {
    url: String,
    /// `None` until [`transport`](ClientBuilder::transport) is called; `build` then falls
    /// back to the built-in WebSocket transport when the `websocket` feature supplies one.
    transport: Option<Arc<dyn Transport>>,
    protocols: Vec<Arc<dyn Protocol>>,
    headers: HeaderMap,
    invalid_header: Option<Error>,
    header_provider: Option<Arc<dyn HeaderProvider>>,
    stop_on_error: Option<Terminal>,
    stale_after: Duration,
    subscribe_retry: Duration,
    initial_backoff: Duration,
    longest_backoff: Duration,
    max_attempts: u32,
    message_buffer: usize,
}

impl ClientBuilder {
    pub(crate) fn new(url: String) -> ClientBuilder {
        ClientBuilder {
            url,
            transport: None,
            protocols: vec![Arc::new(V1Json)],
            headers: HeaderMap::new(),
            invalid_header: None,
            header_provider: None,
            stop_on_error: None,
            stale_after: Duration::from_secs(6),
            subscribe_retry: Duration::from_millis(500),
            initial_backoff: Duration::from_secs(1),
            longest_backoff: Duration::from_secs(30),
            max_attempts: 0,
            message_buffer: 64,
        }
    }

    /// Sets the transport: one of your own, or the built-in [`WebSocketTransport`] configured
    /// differently. Without it `build` uses `WebSocketTransport::default()`, and with the
    /// `websocket` feature off this is the only way to get a client at all.
    ///
    /// [`WebSocketTransport`]: crate::WebSocketTransport
    pub fn transport(mut self, transport: impl Transport + 'static) -> ClientBuilder {
        self.transport = Some(Arc::new(transport));
        self
    }

    /// Sets the protocols offered during the handshake, most preferred first, replacing the
    /// default of [`V1Json`]. The server picks one of them and the client speaks it for the
    /// rest of the connection.
    pub fn protocols(mut self, protocols: Vec<Arc<dyn Protocol>>) -> ClientBuilder {
        self.protocols = protocols;
        self
    }

    /// Offers protocols ahead of the ones already there, so preferring a new protocol
    /// doesn't mean restating the ones to fall back to.
    pub fn prefer_protocols(mut self, protocols: Vec<Arc<dyn Protocol>>) -> ClientBuilder {
        let mut preferred = protocols;
        preferred.append(&mut self.protocols);
        self.protocols = preferred;
        self
    }

    /// Sets a header on the upgrade request. An Action Cable server authorizes that request,
    /// so this is where a session cookie or an API token goes. A name or value that isn't a
    /// valid HTTP header, one carrying a newline say, fails [`build`](ClientBuilder::build).
    pub fn header(mut self, name: &str, value: &str) -> ClientBuilder {
        match parse_header(name, value) {
            Ok((name, value)) => {
                self.headers.insert(name, value);
            }
            Err(error) => {
                self.invalid_header.get_or_insert(error);
            }
        }
        self
    }

    /// Shorthand for one `Cookie` header.
    pub fn cookie(self, cookie: &str) -> ClientBuilder {
        self.header(COOKIE.as_str(), cookie)
    }

    /// Sets the `Origin` header. Rails compares it against the host it serves on and turns
    /// down anything else, a request carrying no `Origin` at all included, so by default it
    /// is derived from the cable URL: `wss://example.com/cable` sends
    /// `https://example.com`. A server behind a proxy that terminates TLS sees a different
    /// scheme than the URL says and needs this.
    pub fn origin(self, origin: &str) -> ClientBuilder {
        self.header(ORIGIN.as_str(), origin)
    }

    /// Asks `provider` for headers on every dial, laid over the ones set here. For a
    /// credential that expires; see [`HeaderProvider`].
    pub fn header_provider(mut self, provider: impl HeaderProvider + 'static) -> ClientBuilder {
        self.header_provider = Some(Arc::new(provider));
        self
    }

    /// Recognizes the connection errors that dialing again cannot repair. The predicate
    /// sees every one of them — a header provider that refused, a dial that failed, a
    /// connection that died — and returning `true` stops the client with that error instead
    /// of reconnecting. [`Error::cause`] hands back the application's own error, for
    /// `downcast_ref` to recognize:
    ///
    /// ```no_run
    /// # use actioncable::Client;
    /// # #[derive(Debug, thiserror::Error)]
    /// # #[error("sign in again")]
    /// # struct SignedOut;
    /// let client = Client::builder("wss://example.com/cable")
    ///     .stop_on_error(|error| error.cause().is_some_and(|cause| cause.is::<SignedOut>()));
    /// ```
    ///
    /// It runs on the connection's task and must return promptly.
    pub fn stop_on_error(
        mut self,
        terminal: impl Fn(&Error) -> bool + Send + Sync + 'static,
    ) -> ClientBuilder {
        self.stop_on_error = Some(Arc::new(terminal));
        self
    }

    /// How long a connection may go without a frame before it counts as dead. The server
    /// beats every three seconds; the default is six, so two missed beats.
    pub fn stale_after(mut self, after: Duration) -> ClientBuilder {
        self.stale_after = after;
        self
    }

    /// The reconnect delay. It starts at `initial`, doubles per failed attempt up to
    /// `longest`, and is spread with jitter. Defaults to a second and half a minute.
    pub fn backoff(mut self, initial: Duration, longest: Duration) -> ClientBuilder {
        self.initial_backoff = initial;
        self.longest_backoff = longest;
        self
    }

    /// How many connection attempts may fail in a row before the client stops with
    /// [`Error::GaveUp`]. A welcome resets the count, so this bounds an outage rather than
    /// the client's lifetime. Zero, the default, keeps dialing until
    /// [`Client::close`](crate::Client::close).
    pub fn max_attempts(mut self, attempts: u32) -> ClientBuilder {
        self.max_attempts = attempts;
        self
    }

    /// How often an unconfirmed subscribe command is resent. Defaults to half a second,
    /// like the JavaScript client's guarantor.
    pub fn subscribe_retry(mut self, retry: Duration) -> ClientBuilder {
        self.subscribe_retry = retry;
        self
    }

    /// How many messages a subscription buffers before it starts dropping them. Defaults
    /// to 64, and applies to every subscription on the client.
    pub fn message_buffer(mut self, messages: usize) -> ClientBuilder {
        self.message_buffer = messages;
        self
    }

    /// Fails on a header that isn't valid HTTP, reported here rather than where it was given
    /// so the chain of setters stays plain, and on having no transport to dial with.
    pub fn build(mut self) -> Result<Client, Error> {
        if let Some(error) = self.invalid_header {
            return Err(error);
        }

        let transport = match self.transport.take() {
            Some(transport) => transport,
            None => default_transport()?,
        };
        self.assume_origin();
        Ok(Client::new(Config {
            url: self.url,
            transport,
            protocols: self.protocols,
            headers: self.headers,
            header_provider: self.header_provider,
            stop_on_error: self.stop_on_error,
            stale_after: self.stale_after,
            subscribe_retry: self.subscribe_retry,
            initial_backoff: self.initial_backoff,
            longest_backoff: self.longest_backoff,
            max_attempts: self.max_attempts,
            message_buffer: self.message_buffer,
        }))
    }

    fn assume_origin(&mut self) {
        if !self.headers.contains_key(ORIGIN)
            && let Some(origin) = origin_of(&self.url)
            && let Ok(origin) = HeaderValue::from_str(&origin)
        {
            self.headers.insert(ORIGIN, origin);
        }
    }
}

#[cfg(feature = "websocket")]
#[allow(
    clippy::unnecessary_wraps,
    reason = "the other half of this pair, without the feature, has nothing to hand back"
)]
fn default_transport() -> Result<Arc<dyn Transport>, Error> {
    Ok(Arc::new(crate::websocket::WebSocketTransport::default()))
}

#[cfg(not(feature = "websocket"))]
fn default_transport() -> Result<Arc<dyn Transport>, Error> {
    Err(Error::NoTransport)
}

fn parse_header(name: &str, value: &str) -> Result<(HeaderName, HeaderValue), Error> {
    let invalid = |source: http::Error| Error::InvalidHeader {
        name: name.to_string(),
        source: Arc::new(source),
    };
    let name = HeaderName::from_bytes(name.as_bytes()).map_err(|error| invalid(error.into()))?;
    let value = HeaderValue::from_str(value).map_err(|error| invalid(error.into()))?;
    Ok((name, value))
}

fn origin_of(url: &str) -> Option<String> {
    let endpoint = Url::parse(url).ok()?;
    let host = endpoint.host_str()?;
    let authority = match endpoint.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    };
    match endpoint.scheme() {
        "wss" | "https" => Some(format!("https://{authority}")),
        "ws" | "http" => Some(format!("http://{authority}")),
        _ => None,
    }
}

/// Everything the builder decided, handed to the client whole.
pub(crate) struct Config {
    pub(crate) url: String,
    pub(crate) transport: Arc<dyn Transport>,
    pub(crate) protocols: Vec<Arc<dyn Protocol>>,
    pub(crate) headers: HeaderMap,
    pub(crate) header_provider: Option<Arc<dyn HeaderProvider>>,
    pub(crate) stop_on_error: Option<Terminal>,
    pub(crate) stale_after: Duration,
    pub(crate) subscribe_retry: Duration,
    pub(crate) initial_backoff: Duration,
    pub(crate) longest_backoff: Duration,
    pub(crate) max_attempts: u32,
    pub(crate) message_buffer: usize,
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use super::*;

    #[test]
    fn the_origin_follows_the_cable_url() {
        let origins = [
            (
                "wss://cable.example.com/cable",
                Some("https://cable.example.com"),
            ),
            (
                "ws://cable.example.com:3000/cable",
                Some("http://cable.example.com:3000"),
            ),
            (
                "wss://cable.example.com:8443/cable",
                Some("https://cable.example.com:8443"),
            ),
            ("ftp://cable.example.com/cable", None),
            ("not a url", None),
        ];

        for (url, origin) in origins {
            assert_eq!(origin.map(str::to_string), origin_of(url), "{url}");
        }
    }

    #[cfg(not(feature = "websocket"))]
    #[test]
    fn without_the_websocket_feature_a_transport_is_required() {
        assert!(matches!(
            Client::builder("wss://cable.example.com/cable").build(),
            Err(Error::NoTransport)
        ));
    }

    #[cfg(feature = "websocket")]
    #[test]
    fn the_websocket_transport_is_the_default() {
        assert!(
            Client::builder("wss://cable.example.com/cable")
                .build()
                .is_ok()
        );
    }
}
