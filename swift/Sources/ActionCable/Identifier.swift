import Foundation

/// The extra attributes that identify a subscription alongside its channel
/// name, like the id of the record a channel streams for.
public typealias Params = [String: JSONValue]

/// Names one subscription. It is encoded as a JSON object and the server treats
/// that encoding as an opaque key, echoing it back on every frame it sends for
/// the subscription.
///
/// ```swift
/// Identifier(channel: "RoomChannel", params: ["id": 42])
/// ```
///
/// A channel with no params needs only the name.
public struct Identifier: Sendable, Hashable {
    public var channel: String
    public var params: Params

    public init(channel: String, params: Params = [:]) {
        self.channel = channel
        self.params = params
    }

    /// The JSON the server knows this subscription by. Keys are sorted, so the
    /// same identifier always keys the same subscription.
    public func key() throws -> String {
        var fields = params
        fields["channel"] = .string(channel)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            return String(decoding: try encoder.encode(fields), as: UTF8.self)
        } catch {
            throw ActionCableError.unencodableIdentifier(channel: channel, underlying: error)
        }
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String {
        if let key = try? key() {
            return key
        } else {
            return "\(channel)(\(params))"
        }
    }
}
