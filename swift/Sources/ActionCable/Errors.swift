import Foundation

/// Everything this client fails with that isn't a transport's own error.
///
/// Go's package matches these with `errors.Is` against sentinel values; Swift
/// has no wrapping, so a case that stands for a failure worth reading carries
/// what it would have wrapped, and callers match with `if case`.
public enum ActionCableError: Error, Sendable {
    /// The client has been closed, or stopped because the server told it not to
    /// reconnect.
    case closed

    /// A command can't be sent because the connection is down. Subscriptions
    /// recover on their own; a `perform` or `send` that hits this is lost and
    /// must be retried.
    case notConnected

    /// The channel's `subscribed` method rejected the subscription.
    case rejected(identifier: String)

    /// The server negotiated a subprotocol none of the protocol adapters speak.
    /// Reconnecting won't fix that, so the client stops.
    case unsupportedSubprotocol(chosen: String, offered: [String])

    /// `connect` was called on a client that is already running.
    case alreadyConnected

    /// There is nothing to offer the server, which means the configuration was
    /// left without any protocols.
    case noProtocols

    /// The client stopped because it failed as many attempts in a row as
    /// `maxAttempts` allows. `lastAttempt` is what the last one failed on.
    case gaveUp(lastAttempt: (any Error)?)

    /// Reported by a subscription after `unsubscribe`.
    case unsubscribed

    /// The server sent a message larger than the transport allows.
    case messageTooBig

    /// The task waiting for the welcome was cancelled — Swift's stand-in for the
    /// deadline Go's `Connect` takes on a context. `lastAttempt` is what the
    /// client was waiting out, so a deadline that ran out on bad credentials
    /// says so.
    case connectCancelled(lastAttempt: (any Error)?)

    /// No frame arrived within `staleAfter`. The server beats a ping every three
    /// seconds, so a connection this quiet is dead.
    case connectionWentQuiet(after: TimeInterval)

    /// An identifier's params don't encode to JSON.
    case unencodableIdentifier(channel: String, underlying: any Error)

    /// The data handed to `perform` or `send` doesn't encode to JSON.
    case unencodableData(underlying: any Error)

    /// The data handed to `perform` encodes to something other than a JSON
    /// object, which leaves nowhere to put the action.
    case dataIsNotAnObject(action: String)
}

extension ActionCableError {
    /// What the most recent connection attempt failed on, for the cases that
    /// stand for giving up on one.
    public var lastAttempt: (any Error)? {
        switch self {
        case .gaveUp(let error), .connectCancelled(let error):
            return error
        default:
            return nil
        }
    }
}

extension ActionCableError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .closed:
            return "actioncable: client closed"
        case .notConnected:
            return "actioncable: not connected"
        case .rejected(let identifier):
            return "actioncable: subscription rejected: \(identifier)"
        case .unsupportedSubprotocol(let chosen, let offered):
            if chosen == Subprotocol.unsupported {
                return
                    "actioncable: unsupported subprotocol: the server speaks none of \(offered.joined(separator: ", "))"
            } else {
                return "actioncable: unsupported subprotocol: \(chosen)"
            }
        case .alreadyConnected:
            return "actioncable: already connected"
        case .noProtocols:
            return "actioncable: no protocols to offer"
        case .gaveUp(let lastAttempt):
            return "actioncable: gave up connecting\(Self.after(lastAttempt))"
        case .unsubscribed:
            return "actioncable: unsubscribed"
        case .messageTooBig:
            return "actioncable: message exceeds the maximum size"
        case .connectCancelled(let lastAttempt):
            return "actioncable: gave up waiting to connect\(Self.after(lastAttempt))"
        case .connectionWentQuiet(let after):
            return "actioncable: no frame in \(after)s"
        case .unencodableIdentifier(let channel, let underlying):
            return "actioncable: encoding identifier for \(channel): \(underlying)"
        case .unencodableData(let underlying):
            return "actioncable: encoding data: \(underlying)"
        case .dataIsNotAnObject(let action):
            return "actioncable: data for \(action) must encode to a JSON object"
        }
    }

    private static func after(_ lastAttempt: (any Error)?) -> String {
        if let lastAttempt {
            return " (last attempt: \(lastAttempt))"
        } else {
            return ""
        }
    }
}

extension ActionCableError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

/// Why an Action Cable server hung up. The wire carries a string, so an
/// unrecognized reason is still readable.
public struct DisconnectReason: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Authentication or authorization failed.
    public static let unauthorized = DisconnectReason(rawValue: "unauthorized")

    /// The request wasn't a valid Action Cable upgrade.
    public static let invalidRequest = DisconnectReason(rawValue: "invalid_request")

    /// The Rails server is restarting.
    public static let serverRestart = DisconnectReason(rawValue: "server_restart")

    /// The app closed this connection with `ActionCable.server.disconnect`.
    public static let remote = DisconnectReason(rawValue: "remote")
}

/// The server sent a disconnect frame.
public struct DisconnectError: Error, Sendable, Hashable {
    public let reason: DisconnectReason
    public let reconnect: Bool

    public init(reason: DisconnectReason, reconnect: Bool) {
        self.reason = reason
        self.reconnect = reconnect
    }
}

extension DisconnectError: CustomStringConvertible, LocalizedError {
    public var description: String {
        "actioncable: server disconnected: \(reason.rawValue)"
    }

    public var errorDescription: String? {
        description
    }
}

/// The server answered the upgrade request with something other than 101
/// Switching Protocols. `statusCode` is what it answered instead, so a caller
/// can tell a redirect from a refusal.
public struct HandshakeError: Error, Sendable, Hashable {
    public let statusCode: Int
    public let status: String

    public init(statusCode: Int, status: String) {
        self.statusCode = statusCode
        self.status = status
    }
}

extension HandshakeError: CustomStringConvertible, LocalizedError {
    public var description: String {
        "actioncable: server refused the upgrade with \(status)"
    }

    public var errorDescription: String? {
        description
    }
}

/// The server closed the connection with a close frame. `code` is the status
/// code the frame carried, 1005 when it carried none, and `reason` is the text
/// after it, if any.
public struct CloseError: Error, Sendable, Hashable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

extension CloseError: CustomStringConvertible, LocalizedError {
    public var description: String {
        if reason.isEmpty {
            return "actioncable: server closed the connection: \(code)"
        } else {
            return "actioncable: server closed the connection: \(code) \(reason)"
        }
    }

    public var errorDescription: String? {
        description
    }
}
