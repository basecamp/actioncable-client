use std::collections::BTreeMap;
use std::fmt;

use serde_json::Value;

/// Names one subscription: a channel and the params that go with it, like the id of the
/// record the channel streams for.
///
/// The server treats the identifier's JSON encoding as an opaque key and echoes it back on
/// every frame it sends for the subscription, so the encoding has to be stable: the keys
/// come out sorted, `channel` among them.
///
/// ```
/// use actioncable::Identifier;
///
/// let room = Identifier::new("RoomChannel").param("id", 42);
/// assert_eq!(r#"{"channel":"RoomChannel","id":42}"#, room.key());
/// ```
///
/// A channel with no params needs only the name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identifier {
    channel: String,
    params: BTreeMap<String, Value>,
}

impl Identifier {
    /// Names a channel, with no params.
    pub fn new(channel: impl Into<String>) -> Identifier {
        Identifier {
            channel: channel.into(),
            params: BTreeMap::new(),
        }
    }

    /// Adds one param, like the id of the record the channel streams for.
    pub fn param(mut self, name: impl Into<String>, value: impl Into<Value>) -> Identifier {
        self.params.insert(name.into(), value.into());
        self
    }

    /// The channel's name.
    pub fn channel(&self) -> &str {
        &self.channel
    }

    /// The params, sorted by name as the key encodes them.
    pub fn params(&self) -> &BTreeMap<String, Value> {
        &self.params
    }

    /// The JSON string the server knows the subscription by. A param named `channel` loses
    /// to the channel name.
    ///
    /// Where the Go client returns an error, this cannot fail: a param is a
    /// [`serde_json::Value`], and a map of them always encodes.
    #[allow(
        clippy::expect_used,
        reason = "serializing a map of Values has no failure mode to report"
    )]
    pub fn key(&self) -> String {
        let mut fields = self.params.clone();
        fields.insert("channel".to_string(), Value::String(self.channel.clone()));
        serde_json::to_string(&fields).expect("a map of JSON values always encodes")
    }
}

impl fmt::Display for Identifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.key())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_is_the_sorted_json_encoding() {
        let identifiers = [
            (
                Identifier::new("RoomChannel"),
                r#"{"channel":"RoomChannel"}"#,
            ),
            (
                Identifier::new("RoomChannel").param("id", 42),
                r#"{"channel":"RoomChannel","id":42}"#,
            ),
            (
                Identifier::new("RoomChannel")
                    .param("since", "yesterday")
                    .param("id", 42),
                r#"{"channel":"RoomChannel","id":42,"since":"yesterday"}"#,
            ),
            (
                Identifier::new("RoomChannel").param("channel", "impostor"),
                r#"{"channel":"RoomChannel"}"#,
            ),
        ];

        for (identifier, key) in identifiers {
            assert_eq!(key, identifier.key());
            assert_eq!(key, identifier.to_string());
        }
    }

    /// The Go client's key can fail on params that don't encode. Here they can't exist: a
    /// param is a `Value`, and a float JSON has no spelling for is one before it arrives.
    #[test]
    fn an_identifier_always_encodes() {
        let identifier = Identifier::new("RoomChannel").param("id", f64::NAN);

        assert_eq!(r#"{"channel":"RoomChannel","id":null}"#, identifier.key());
    }
}
