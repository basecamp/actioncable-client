import ActionCable
import Foundation

/// Speaks a made-up subprotocol and stamps everything it encodes, so a test can
/// tell which protocol the client settled on.
public struct FakeProtocol: CableProtocol {
    public let subprotocol: String
    public let stamp: String

    public init(subprotocol: String, stamp: String) {
        self.subprotocol = subprotocol
        self.stamp = stamp
    }

    public func encode(_ command: Command) throws -> Data {
        Data(stamp.utf8) + (try V1JSON().encode(command))
    }

    public func decode(_ payload: Data) throws -> Incoming {
        let stamped = Data(stamp.utf8)

        if payload.starts(with: stamped) {
            return try V1JSON().decode(payload.dropFirst(stamped.count))
        } else {
            return try V1JSON().decode(payload)
        }
    }
}
