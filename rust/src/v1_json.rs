use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use crate::error::{DisconnectReason, Error};
use crate::message::Message;
use crate::protocol::{Command, Incoming, Kind, Protocol};

/// The subprotocol every Rails Action Cable server speaks.
pub const SUBPROTOCOL_V1_JSON: &str = "actioncable-v1-json";

/// The `actioncable-v1-json` protocol: JSON objects in text frames, keyed by `command` going
/// out and by `type` coming in.
#[derive(Debug, Clone, Copy, Default)]
pub struct V1Json;

impl Protocol for V1Json {
    fn subprotocol(&self) -> &str {
        SUBPROTOCOL_V1_JSON
    }

    fn encode(&self, command: &Command) -> Result<Vec<u8>, Error> {
        Ok(serde_json::to_vec(&Outgoing {
            command: command.name.as_str(),
            identifier: &command.identifier,
            data: command.data.as_deref(),
        })?)
    }

    fn decode(&self, payload: &[u8]) -> Result<Incoming, Error> {
        let frame: Frame = serde_json::from_slice(payload)?;
        let kind = match frame.r#type.as_deref() {
            Some("welcome") => Kind::Welcome,
            Some("ping") => Kind::Ping,
            Some("disconnect") => Kind::Disconnect,
            Some("confirm_subscription") => Kind::Confirmation,
            Some("reject_subscription") => Kind::Rejection,
            _ => Kind::Message,
        };

        Ok(Incoming {
            kind,
            identifier: frame.identifier.unwrap_or_default(),
            message: frame.message.map(|raw| Message::from_json(raw.get())),
            reason: frame.reason.as_deref().map(DisconnectReason::parse),
            reconnect: frame.reconnect,
        })
    }
}

#[derive(Serialize)]
struct Outgoing<'a> {
    command: &'a str,
    identifier: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<&'a str>,
}

/// Anything without a recognized type is a channel message, which is how the server sends
/// them: an identifier and a message, and no type at all.
#[derive(Deserialize)]
struct Frame {
    r#type: Option<String>,
    identifier: Option<String>,
    message: Option<Box<RawValue>>,
    reason: Option<String>,
    #[serde(default)]
    reconnect: bool,
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use super::*;
    use crate::protocol::CommandName;

    #[test]
    fn the_subprotocol_is_rails_default() {
        assert_eq!("actioncable-v1-json", V1Json.subprotocol());
    }

    #[test]
    fn commands_encode_keyed_by_command() {
        let commands = [
            (
                Command::subscribe(r#"{"channel":"RoomChannel"}"#),
                r#"{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
            ),
            (
                Command::unsubscribe(r#"{"channel":"RoomChannel"}"#),
                r#"{"command":"unsubscribe","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
            ),
            (
                Command::message(r#"{"channel":"RoomChannel"}"#, r#"{"action":"speak"}"#),
                r#"{"command":"message","identifier":"{\"channel\":\"RoomChannel\"}","data":"{\"action\":\"speak\"}"}"#,
            ),
        ];

        for (command, encoded) in commands {
            assert_eq!(
                encoded,
                String::from_utf8(V1Json.encode(&command).unwrap()).unwrap()
            );
        }
        assert_eq!("message", CommandName::Message.to_string());
    }

    #[test]
    fn frames_decode_keyed_by_type() {
        let room = r#"{"channel":"RoomChannel"}"#;
        let frames = [
            (r#"{"type":"welcome"}"#, Incoming::new(Kind::Welcome)),
            (
                r#"{"type":"ping","message":1755400000}"#,
                Incoming {
                    message: Some(Message::from_json("1755400000")),
                    ..Incoming::new(Kind::Ping)
                },
            ),
            (
                r#"{"type":"disconnect","reason":"server_restart","reconnect":true}"#,
                Incoming {
                    reason: Some(DisconnectReason::ServerRestart),
                    reconnect: true,
                    ..Incoming::new(Kind::Disconnect)
                },
            ),
            (
                r#"{"type":"confirm_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
                Incoming {
                    identifier: room.to_string(),
                    ..Incoming::new(Kind::Confirmation)
                },
            ),
            (
                r#"{"type":"reject_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
                Incoming {
                    identifier: room.to_string(),
                    ..Incoming::new(Kind::Rejection)
                },
            ),
            (
                r#"{"identifier":"{\"channel\":\"RoomChannel\"}","message":{"body":"Hello!"}}"#,
                Incoming {
                    identifier: room.to_string(),
                    message: Some(Message::from_json(r#"{"body":"Hello!"}"#)),
                    ..Incoming::new(Kind::Message)
                },
            ),
            (
                r#"{"type":"something_new","identifier":"x","message":"anything"}"#,
                Incoming {
                    identifier: "x".to_string(),
                    message: Some(Message::from_json(r#""anything""#)),
                    ..Incoming::new(Kind::Message)
                },
            ),
        ];

        for (payload, expected) in frames {
            assert_eq!(
                expected,
                V1Json.decode(payload.as_bytes()).unwrap(),
                "{payload}"
            );
        }
    }

    #[test]
    fn garbage_does_not_decode() {
        assert!(matches!(V1Json.decode(b"not json"), Err(Error::Json(_))));
    }

    #[test]
    fn kinds_display_as_the_wire_types() {
        let kinds = [
            (Kind::Welcome, "welcome"),
            (Kind::Ping, "ping"),
            (Kind::Disconnect, "disconnect"),
            (Kind::Confirmation, "confirm_subscription"),
            (Kind::Rejection, "reject_subscription"),
            (Kind::Message, "message"),
        ];

        for (kind, name) in kinds {
            assert_eq!(name, kind.to_string());
        }
    }
}
