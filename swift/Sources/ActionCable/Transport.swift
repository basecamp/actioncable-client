import Foundation

/// What the client needs the transport to negotiate: the subprotocols its
/// protocol adapters speak, and the headers that authenticate the request — a
/// cookie or a token, since an Action Cable server authorizes the upgrade
/// request itself.
public struct DialOptions: Sendable, Hashable {
    public var subprotocols: [String]
    public var headers: [String: String]

    public init(subprotocols: [String] = [], headers: [String: String] = [:]) {
        self.subprotocols = subprotocols
        self.headers = headers
    }
}

/// Dials the network connection a client talks over. It is the seam where a
/// network handler plugs in: the built-in ``URLSessionTransport`` speaks
/// RFC 6455 through `URLSessionWebSocketTask`, and wrapping another WebSocket
/// package, or an in-memory pipe for tests, means implementing these two
/// protocols and nothing else.
public protocol Transport: Sendable {
    func dial(url: String, options: DialOptions) async throws -> any Connection
}

/// One live connection.
///
/// `read` and `write` are each called from one task at a time, but `close` may
/// be called while either is running, and must interrupt them. So must
/// cancelling the task that is reading or writing: that is how the client hangs
/// up a connection that has gone quiet.
public protocol Connection: Sendable {
    /// What the server negotiated, empty if it named none.
    var subprotocol: String { get }

    /// The next complete message. It throws once the connection is unusable,
    /// including when the reading task is cancelled.
    func read() async throws -> Data

    /// Sends one text message.
    func write(_ payload: Data) async throws

    func close() async
}

/// A connection that can say why it is hanging up. ``Connection/close()`` sends
/// a close frame with 1000 Normal Closure; `close(code:reason:)` sends one with
/// the code and reason given, for a caller with something to tell the server.
/// The built-in transport's connections implement it.
public protocol StatusClosing: Connection {
    func close(code: Int, reason: String) async
}
