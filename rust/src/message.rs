use std::fmt;

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::error::Error;

/// The undecoded payload a channel broadcast or transmitted, exactly as it came off the
/// wire. Its shape is entirely up to the channel, so [`decode`](Message::decode) it into
/// the type you expect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    json: String,
}

impl Message {
    /// Wraps JSON text without checking it. For protocol implementations, which have
    /// already parsed the frame around it.
    pub fn from_json(json: impl Into<String>) -> Message {
        Message { json: json.into() }
    }

    /// Decodes the payload into the type the channel sends.
    pub fn decode<T: DeserializeOwned>(&self) -> Result<T, Error> {
        Ok(serde_json::from_str(&self.json)?)
    }

    /// Decodes the payload into a [`serde_json::Value`], for a shape known at runtime.
    pub fn to_value(&self) -> Result<Value, Error> {
        self.decode()
    }

    /// The payload's JSON text, as it came off the wire.
    pub fn as_str(&self) -> &str {
        &self.json
    }
}

impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.json)
    }
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use serde::Deserialize;

    use super::*;

    #[derive(Debug, PartialEq, Deserialize)]
    struct Said {
        body: String,
    }

    #[test]
    fn a_message_decodes_into_the_callers_type() {
        let message = Message::from_json(r#"{"body":"Hello!"}"#);

        let said: Said = message.decode().unwrap();

        assert_eq!("Hello!", said.body);
        assert_eq!(r#"{"body":"Hello!"}"#, message.to_string());
        assert!(matches!(
            Message::from_json("not json").decode::<Said>(),
            Err(Error::Json(_))
        ));
    }
}
