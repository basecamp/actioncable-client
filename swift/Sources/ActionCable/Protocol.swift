import Foundation

/// The WebSocket subprotocols this package knows by name.
public enum Subprotocol {
    /// What every Rails Action Cable server speaks.
    public static let v1JSON = "actioncable-v1-json"

    /// The sentinel an Action Cable server names when it speaks none of the
    /// subprotocols offered. The client offers it last on every handshake, the
    /// way Rails' own clients do, so a server with nothing in common can say so
    /// outright instead of leaving the subprotocol blank.
    public static let unsupported = "actioncable-unsupported"
}

/// Translates between Action Cable commands and the bytes on the wire. It is
/// the seam where an Action Cable protocol plugs in.
///
/// One protocol speaks one subprotocol. A client offers every protocol it was
/// given and speaks the one the server picks, so supporting a new protocol
/// means adding one rather than replacing the list.
public protocol CableProtocol: Sendable {
    /// The name this protocol negotiates under.
    var subprotocol: String { get }

    /// Turns a command into one outgoing message.
    func encode(_ command: Command) throws -> Data

    /// Turns one incoming message into a frame the client understands.
    func decode(_ payload: Data) throws -> Incoming
}

/// The verb of a client-to-server command.
public enum CommandName: String, Sendable, Hashable {
    case subscribe
    case unsubscribe
    case message
}

/// A client-to-server message. `data` carries the already encoded action
/// payload and is only set for `.message`.
public struct Command: Sendable, Hashable {
    public var name: CommandName
    public var identifier: String
    public var data: String?

    public init(name: CommandName, identifier: String, data: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.data = data
    }
}

/// The type of a server-to-client frame.
public enum Kind: String, Sendable, Hashable {
    case welcome
    case ping
    case disconnect
    case confirmation = "confirm_subscription"
    case rejection = "reject_subscription"
    case message
}

/// A decoded server-to-client frame. `reason` and `reconnect` are only set on
/// `.disconnect`, `message` on `.message` and `.ping`.
public struct Incoming: Sendable, Hashable {
    public var kind: Kind
    public var identifier: String
    public var message: Message?
    public var reason: DisconnectReason
    public var reconnect: Bool

    public init(
        kind: Kind,
        identifier: String = "",
        message: Message? = nil,
        reason: DisconnectReason = DisconnectReason(rawValue: ""),
        reconnect: Bool = false
    ) {
        self.kind = kind
        self.identifier = identifier
        self.message = message
        self.reason = reason
        self.reconnect = reconnect
    }
}
