import Foundation

/// The undecoded payload a channel broadcast or transmitted. Its shape is
/// entirely up to the channel, so `decode` it into the expected type.
public struct Message: Sendable, Hashable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data)
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

extension Message: CustomStringConvertible {
    public var description: String {
        text
    }
}
