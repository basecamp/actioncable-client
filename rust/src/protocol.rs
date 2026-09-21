use std::fmt;

use crate::error::{DisconnectReason, Error};
use crate::message::Message;

/// Translates between Action Cable commands and the bytes on the wire. It is the seam where
/// an Action Cable protocol plugs in.
///
/// One protocol speaks one subprotocol. A client offers every protocol it was given and
/// speaks the one the server picks, so supporting a new protocol means adding one rather
/// than replacing the list.
pub trait Protocol: Send + Sync {
    /// The name this protocol negotiates under.
    fn subprotocol(&self) -> &str;

    /// Turns a command into one outgoing message.
    fn encode(&self, command: &Command) -> Result<Vec<u8>, Error>;

    /// Turns one incoming message into a frame the client understands. A frame of
    /// [`Kind::Message`] must carry a [`message`](Incoming::message); the client drops one
    /// that doesn't, where the Go client delivers an empty message.
    fn decode(&self, payload: &[u8]) -> Result<Incoming, Error>;
}

/// The sentinel an Action Cable server names when it speaks none of the subprotocols
/// offered. The client offers it last on every handshake, the way Rails' own clients do, so
/// a server with nothing in common can say so outright instead of leaving the subprotocol
/// blank.
pub const SUBPROTOCOL_UNSUPPORTED: &str = "actioncable-unsupported";

/// The verb of a client-to-server command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandName {
    /// Asks the server for a subscription to one identifier.
    Subscribe,
    /// Tells the server to drop one.
    Unsubscribe,
    /// Carries a payload to the channel.
    Message,
}

impl CommandName {
    /// The verb as the wire spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            CommandName::Subscribe => "subscribe",
            CommandName::Unsubscribe => "unsubscribe",
            CommandName::Message => "message",
        }
    }
}

impl fmt::Display for CommandName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A client-to-server message. `data` carries the already encoded action payload and is
/// only set for [`CommandName::Message`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// The verb.
    pub name: CommandName,
    /// The identifier the command is about, as [`Identifier::key`](crate::Identifier::key)
    /// spells it.
    pub identifier: String,
    /// The already encoded action payload, on a [`CommandName::Message`] and nothing else.
    pub data: Option<String>,
}

impl Command {
    /// Asks for a subscription to `identifier`.
    pub fn subscribe(identifier: impl Into<String>) -> Command {
        Command {
            name: CommandName::Subscribe,
            identifier: identifier.into(),
            data: None,
        }
    }

    /// Tells the server to drop `identifier`.
    pub fn unsubscribe(identifier: impl Into<String>) -> Command {
        Command {
            name: CommandName::Unsubscribe,
            identifier: identifier.into(),
            data: None,
        }
    }

    /// Carries `data`, already encoded, to the channel behind `identifier`.
    pub fn message(identifier: impl Into<String>, data: impl Into<String>) -> Command {
        Command {
            name: CommandName::Message,
            identifier: identifier.into(),
            data: Some(data.into()),
        }
    }
}

/// The type of a server-to-client frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// The server finished setting the connection up and will act on commands from here.
    Welcome,
    /// The heartbeat, every three seconds.
    Ping,
    /// The server is hanging up, and says whether to come back.
    Disconnect,
    /// The channel accepted a subscription.
    Confirmation,
    /// The channel turned one down.
    Rejection,
    /// Something a channel broadcast or transmitted.
    Message,
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Kind::Welcome => "welcome",
            Kind::Ping => "ping",
            Kind::Disconnect => "disconnect",
            Kind::Confirmation => "confirm_subscription",
            Kind::Rejection => "reject_subscription",
            Kind::Message => "message",
        })
    }
}

/// A decoded server-to-client frame. `reason` and `reconnect` are only set on
/// [`Kind::Disconnect`], `message` on [`Kind::Message`] and [`Kind::Ping`], and the
/// identifier is empty on the frames that concern the connection rather than a
/// subscription. A [`Kind::Message`] frame with no `message` is dropped and logged rather
/// than delivered empty, which is where this client parts from the Go one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Incoming {
    /// What the server sent.
    pub kind: Kind,
    /// The subscription it is about, empty on the frames about the connection itself.
    pub identifier: String,
    /// The payload, on [`Kind::Message`] and [`Kind::Ping`].
    pub message: Option<Message>,
    /// Why the server is hanging up, on [`Kind::Disconnect`].
    pub reason: Option<DisconnectReason>,
    /// Whether the server expects the client back, on [`Kind::Disconnect`].
    pub reconnect: bool,
}

impl Incoming {
    /// An otherwise empty frame of `kind`, to fill in.
    pub fn new(kind: Kind) -> Incoming {
        Incoming {
            kind,
            identifier: String::new(),
            message: None,
            reason: None,
            reconnect: false,
        }
    }
}
