use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use crate::protocol::SUBPROTOCOL_UNSUPPORTED;

/// Everything a caller can get back from a cable. It is `Clone` because a client that stopped
/// for good hands the same failure to everyone who asks it afterwards.
///
/// Which method returns what:
///
/// - `build`: [`InvalidHeader`](Error::InvalidHeader), [`NoTransport`](Error::NoTransport).
/// - `connect`: [`AlreadyConnected`](Error::AlreadyConnected), then whatever stopped the
///   client: [`Closed`](Error::Closed), [`NoProtocols`](Error::NoProtocols),
///   [`UnsupportedSubprotocol`](Error::UnsupportedSubprotocol),
///   [`Disconnected`](Error::Disconnected), [`GaveUp`](Error::GaveUp) or an error
///   [`ClientBuilder::stop_on_error`](crate::ClientBuilder::stop_on_error) called terminal.
/// - `subscribe`: [`NotConnected`](Error::NotConnected) before `connect`,
///   [`Rejected`](Error::Rejected), or whatever stopped the client.
/// - `perform`, `send` and `unsubscribe`: [`Closed`](Error::Closed),
///   [`NotConnected`](Error::NotConnected), [`Transport`](Error::Transport),
///   [`DataNotAnObject`](Error::DataNotAnObject) and [`Json`](Error::Json).
/// - `Subscription::err`: [`Unsubscribed`](Error::Unsubscribed),
///   [`Rejected`](Error::Rejected), or whatever stopped the client.
/// - `Message::decode`: [`Json`](Error::Json).
///
/// The built-in transport reports three of its failures by name, for a caller that wants to
/// act on them rather than read them: [`Handshake`](Error::Handshake),
/// [`Close`](Error::Close) and [`MessageTooBig`](Error::MessageTooBig). Anything else a
/// transport hits arrives as [`Transport`](Error::Transport), and whatever a
/// [`HeaderProvider`](crate::HeaderProvider) failed on as [`Headers`](Error::Headers); both
/// keep the original error, and [`cause`](Error::cause) hands it back for an application to
/// recognize with `downcast_ref`.
#[derive(Debug, Clone, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    /// The client was closed, or nothing holds it any more. A client that stopped on its own
    /// hands out what stopped it instead.
    #[error("client closed")]
    Closed,

    /// A command couldn't be sent because the connection is down, or up but not yet
    /// welcomed. Subscriptions recover on their own; a `perform` or `send` that hits this
    /// is lost and has to be sent again. `subscribe` before `connect` gets it too.
    #[error("not connected")]
    NotConnected,

    /// `connect` was called on a client that is already running.
    #[error("already connected")]
    AlreadyConnected,

    /// The protocol list was replaced with nothing, so there is nothing to offer the server.
    #[error("no protocols to offer")]
    NoProtocols,

    /// No transport was given and the `websocket` feature that supplies the built-in one is
    /// off, so there is nothing to dial with.
    #[error("no transport: set one with ClientBuilder::transport or enable the websocket feature")]
    NoTransport,

    /// The channel's `subscribed` method rejected the subscription. `key` is the identifier
    /// as the server knows it, [`Identifier::key`](crate::Identifier::key).
    #[error("subscription rejected: {key}")]
    Rejected {
        /// The identifier the server turned down.
        key: String,
    },

    /// What [`Subscription::err`](crate::Subscription::err) reports after
    /// [`unsubscribe`](crate::Subscription::unsubscribe).
    #[error("unsubscribed")]
    Unsubscribed,

    /// The server negotiated a subprotocol none of the client's protocols speak, none at
    /// all, or the `actioncable-unsupported` sentinel that says it speaks none of what was
    /// offered. Reconnecting won't fix that, so the client stops.
    #[error(
        "unsupported subprotocol: {}",
        describe_subprotocol(negotiated, offered)
    )]
    UnsupportedSubprotocol {
        /// What the server named, empty when it named nothing.
        negotiated: String,
        /// The subprotocols that were offered, most preferred first.
        offered: Vec<String>,
    },

    /// The server sent a disconnect frame. `reason` is `None` when the frame named none,
    /// and `reconnect` is what the frame said about coming back: the client stops on a
    /// disconnect that says not to, and dials again on one that says to.
    #[error("server disconnected{}", describe_reason(reason.as_ref()))]
    Disconnected {
        /// Why the server hung up, as it spelled it.
        reason: Option<DisconnectReason>,
        /// Whether the server expects the client back.
        reconnect: bool,
    },

    /// As many connection attempts failed in a row as
    /// [`ClientBuilder::max_attempts`](crate::ClientBuilder::max_attempts) allows, so the
    /// client stopped. A welcome resets the count, so this bounds one outage rather than the
    /// client's lifetime.
    #[error("gave up connecting after {attempts} attempts: {last}")]
    GaveUp {
        /// How many attempts failed in a row.
        attempts: u32,
        /// What the last of them failed on.
        #[source]
        last: Box<Error>,
    },

    /// The connection went quiet for longer than
    /// [`ClientBuilder::stale_after`](crate::ClientBuilder::stale_after). The server beats a
    /// ping every three seconds, so silence means the connection is dead; it is dropped and
    /// redialed.
    #[error("no frame in {after:?}")]
    Stale {
        /// How long the client waited.
        after: Duration,
    },

    /// The server answered the upgrade request with something other than 101 Switching
    /// Protocols. `status` tells a redirect from a refusal, and prints as the whole status
    /// line.
    #[error("server refused the upgrade with {status}")]
    Handshake {
        /// What the server answered instead.
        status: http::StatusCode,
    },

    /// The server closed the connection with a close frame. `code` is the status code it
    /// carried, 1005 when it carried none, and `reason` the text after it, if any.
    #[error("server closed the connection: {}", describe_close(*code, reason))]
    Close {
        /// RFC 6455's close code.
        code: u16,
        /// What the frame said, empty when it said nothing.
        reason: String,
    },

    /// The server sent a message larger than the transport allows. It is refused as soon as
    /// its length is known, before any of it is read in, and the connection is failed.
    #[error("message of {size} bytes exceeds the maximum of {limit}")]
    MessageTooBig {
        /// The size the frame claimed.
        size: usize,
        /// The largest message this transport accepts.
        limit: usize,
    },

    /// The transport failed to dial, read or write. A failed dial or read is redialed and
    /// only logged; a failed write comes back from the `perform`, `send` or `unsubscribe`
    /// that asked for it, and the connection is dropped and redialed.
    #[error("transport: {0}")]
    Transport(#[source] Arc<dyn std::error::Error + Send + Sync>),

    /// The header provider couldn't produce headers for a dial. That dial is turned down
    /// and the client tries again on its backoff.
    #[error("building headers: {0}")]
    Headers(#[source] Arc<dyn std::error::Error + Send + Sync>),

    /// A header given to the builder is not a valid HTTP header.
    #[error("invalid header {name}: {source}")]
    InvalidHeader {
        /// The header that was refused.
        name: String,
        /// What `http` said about it.
        #[source]
        source: Arc<http::Error>,
    },

    /// The data given to `perform` encodes to something other than a JSON object, which is
    /// the only shape Rails will route to an action.
    #[error("data for {action:?} must encode to a JSON object")]
    DataNotAnObject {
        /// The action the data was for.
        action: String,
    },

    /// A message didn't decode into the type asked for, data for `perform` or `send` didn't
    /// encode, or a frame wasn't the JSON the protocol expects.
    #[error("json: {0}")]
    Json(#[source] Arc<serde_json::Error>),
}

impl Error {
    /// Wraps a transport's own error, for [`Transport`](crate::Transport) and
    /// [`Conn`](crate::Conn) implementations.
    pub fn transport(source: impl std::error::Error + Send + Sync + 'static) -> Error {
        Error::Transport(Arc::new(source))
    }

    /// Wraps whatever stopped a [`HeaderProvider`](crate::HeaderProvider) from answering.
    pub fn headers(source: impl std::error::Error + Send + Sync + 'static) -> Error {
        Error::Headers(Arc::new(source))
    }

    /// The error underneath this one, as the transport or the header provider handed it
    /// over, for a caller that wants to recognize its own with `downcast_ref`:
    ///
    /// ```
    /// # use actioncable::Error;
    /// # #[derive(Debug, thiserror::Error)]
    /// # #[error("sign in again")]
    /// # struct SignedOut;
    /// let error = Error::headers(SignedOut);
    ///
    /// assert!(error.cause().is_some_and(|cause| cause.is::<SignedOut>()));
    /// ```
    ///
    /// [`GaveUp`](Error::GaveUp) hands back what the last attempt failed on, since that is
    /// the error the caller was waiting out. Everything else has no error underneath it and
    /// answers `None`.
    ///
    /// This is here rather than left to [`source`](std::error::Error::source) because the
    /// wrapped error is held behind an `Arc`, and a `source` walk hands back the `Arc`
    /// rather than what is in it. `source` still prints the chain; `cause` is what
    /// `downcast_ref` works on.
    pub fn cause(&self) -> Option<&(dyn std::error::Error + Send + Sync + 'static)> {
        match self {
            Error::Transport(cause) | Error::Headers(cause) => Some(&**cause),
            Error::GaveUp { last, .. } => last.cause(),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for Error {
    fn from(source: serde_json::Error) -> Error {
        Error::Json(Arc::new(source))
    }
}

fn describe_subprotocol(negotiated: &str, offered: &[String]) -> String {
    if negotiated == SUBPROTOCOL_UNSUPPORTED {
        format!("the server speaks none of {}", offered.join(", "))
    } else {
        format!("{negotiated:?}")
    }
}

fn describe_reason(reason: Option<&DisconnectReason>) -> String {
    match reason {
        Some(reason) => format!(": {reason}"),
        None => String::new(),
    }
}

fn describe_close(code: u16, reason: &str) -> String {
    if reason.is_empty() {
        code.to_string()
    } else {
        format!("{code} {reason}")
    }
}

/// Why an Action Cable server hung up. Rails names four; anything else it might send in the
/// future arrives as [`Other`](DisconnectReason::Other).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisconnectReason {
    /// Authentication or authorization failed.
    Unauthorized,
    /// The request wasn't a valid Action Cable upgrade.
    InvalidRequest,
    /// The Rails server is restarting.
    ServerRestart,
    /// The app closed this connection with `ActionCable.server.disconnect`.
    Remote,
    /// Something this client doesn't know, as the server spelled it.
    Other(String),
}

impl DisconnectReason {
    /// The reason from its wire spelling, for protocol implementations.
    pub fn parse(reason: &str) -> DisconnectReason {
        match reason {
            "unauthorized" => DisconnectReason::Unauthorized,
            "invalid_request" => DisconnectReason::InvalidRequest,
            "server_restart" => DisconnectReason::ServerRestart,
            "remote" => DisconnectReason::Remote,
            other => DisconnectReason::Other(other.to_string()),
        }
    }

    /// The reason as the server spells it.
    pub fn as_str(&self) -> &str {
        match self {
            DisconnectReason::Unauthorized => "unauthorized",
            DisconnectReason::InvalidRequest => "invalid_request",
            DisconnectReason::ServerRestart => "server_restart",
            DisconnectReason::Remote => "remote",
            DisconnectReason::Other(other) => other,
        }
    }
}

impl fmt::Display for DisconnectReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use std::error::Error as _;
    use std::io;

    use super::*;

    #[test]
    fn disconnect_reasons_round_trip() {
        for (wire, reason) in [
            ("unauthorized", DisconnectReason::Unauthorized),
            ("invalid_request", DisconnectReason::InvalidRequest),
            ("server_restart", DisconnectReason::ServerRestart),
            ("remote", DisconnectReason::Remote),
            ("moved", DisconnectReason::Other("moved".to_string())),
        ] {
            assert_eq!(reason, DisconnectReason::parse(wire));
            assert_eq!(wire, DisconnectReason::parse(wire).to_string());
        }
    }

    #[test]
    fn a_disconnect_names_its_reason_when_the_server_gave_one() {
        assert_eq!(
            "server disconnected: unauthorized",
            Error::Disconnected {
                reason: Some(DisconnectReason::Unauthorized),
                reconnect: false,
            }
            .to_string()
        );
        assert_eq!(
            "server disconnected",
            Error::Disconnected {
                reason: None,
                reconnect: false,
            }
            .to_string()
        );
    }

    #[test]
    fn unsupported_subprotocol_describes_what_was_offered() {
        let sentinel = Error::UnsupportedSubprotocol {
            negotiated: SUBPROTOCOL_UNSUPPORTED.to_string(),
            offered: vec!["actioncable-v1-json".to_string(), "v2".to_string()],
        };
        let unknown = Error::UnsupportedSubprotocol {
            negotiated: "actioncable-v9-telepathy".to_string(),
            offered: vec!["actioncable-v1-json".to_string()],
        };

        assert_eq!(
            "unsupported subprotocol: the server speaks none of actioncable-v1-json, v2",
            sentinel.to_string()
        );
        assert_eq!(
            "unsupported subprotocol: \"actioncable-v9-telepathy\"",
            unknown.to_string()
        );
    }

    #[test]
    fn a_close_reads_as_the_frame_the_server_sent() {
        assert_eq!(
            "server closed the connection: 4401 unauthorized",
            Error::Close {
                code: 4401,
                reason: "unauthorized".to_string(),
            }
            .to_string()
        );
        assert_eq!(
            "server closed the connection: 1005",
            Error::Close {
                code: 1005,
                reason: String::new(),
            }
            .to_string()
        );
    }

    #[test]
    fn a_handshake_failure_reads_as_the_status_line() {
        let refused = Error::Handshake {
            status: http::StatusCode::NOT_FOUND,
        };

        assert_eq!(
            "server refused the upgrade with 404 Not Found",
            refused.to_string()
        );
    }

    #[test]
    fn giving_up_keeps_what_the_last_attempt_failed_on() {
        let gave_up = Error::GaveUp {
            attempts: 2,
            last: Box::new(Error::transport(io::Error::other("connection refused"))),
        };

        assert_eq!(
            "gave up connecting after 2 attempts: transport: connection refused",
            gave_up.to_string()
        );
        assert_eq!(
            "connection refused",
            gave_up
                .cause()
                .expect("the last attempt's own error")
                .to_string()
        );
        assert!(gave_up.source().is_some(), "the chain still prints");
    }

    #[test]
    fn a_wrapped_error_can_be_recognized_by_its_own_type() {
        let signed_out = Error::headers(io::Error::other("sign in again"));

        let cause = signed_out
            .cause()
            .and_then(<dyn std::error::Error + Send + Sync>::downcast_ref::<io::Error>)
            .expect("the provider's own error");
        assert_eq!("sign in again", cause.to_string());
        assert_eq!(None, Error::Closed.cause().map(ToString::to_string));
    }
}
