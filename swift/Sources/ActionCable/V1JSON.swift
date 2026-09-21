import Foundation

/// Implements the `actioncable-v1-json` protocol: JSON objects in text frames,
/// keyed by command going out and by type coming in.
public struct V1JSON: CableProtocol {
    public init() {}

    public var subprotocol: String {
        Subprotocol.v1JSON
    }

    /// Written out field by field rather than encoded from a struct:
    /// `JSONEncoder` gives no order to a keyed container's fields, and a
    /// command should read the same way on the wire as every other Action
    /// Cable client's does.
    public func encode(_ command: Command) throws -> Data {
        var json = "{\"command\":" + Self.quoted(command.name.rawValue)
        json += ",\"identifier\":" + Self.quoted(command.identifier)

        if let data = command.data {
            json += ",\"data\":" + Self.quoted(data)
        }

        return Data((json + "}").utf8)
    }

    private static func quoted(_ value: String) -> String {
        var quoted = "\""

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                quoted += "\\\""
            case "\\":
                quoted += "\\\\"
            case "\n":
                quoted += "\\n"
            case "\r":
                quoted += "\\r"
            case "\t":
                quoted += "\\t"
            default:
                if scalar.value < 0x20 {
                    quoted += String(format: "\\u%04x", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }

        return quoted + "\""
    }

    public func decode(_ payload: Data) throws -> Incoming {
        let frame = try JSONDecoder().decode(IncomingFrame.self, from: payload)

        return Incoming(
            // Anything without a recognized type is a channel message, which is
            // how the server sends them: an identifier and a message, and no
            // type at all.
            kind: frame.type.flatMap(Kind.init(rawValue:)) ?? .message,
            identifier: frame.identifier ?? "",
            message: try frame.message.map(Self.rendered),
            reason: DisconnectReason(rawValue: frame.reason ?? ""),
            reconnect: frame.reconnect ?? false
        )
    }

    /// A message's JSON as text. Go hands the server's own bytes through
    /// untouched; Swift's decoder gives no way to reach them, so the value is
    /// rendered again with its object keys sorted. The value is the same; the
    /// byte order of a multi-key object need not be.
    private static func rendered(_ value: JSONValue) throws -> Message {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        return Message(try encoder.encode(value))
    }
}

private struct IncomingFrame: Decodable {
    let type: String?
    let identifier: String?
    let message: JSONValue?
    let reason: String?
    let reconnect: Bool?
}
