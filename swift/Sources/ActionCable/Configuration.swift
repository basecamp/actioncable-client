import Foundation

extension ActionCableClient {
    /// Everything a client can be told before it dials. Go passes these as
    /// functional options; Swift takes the whole thing at once, so the defaults
    /// live here where they can be read in one go.
    public struct Configuration: Sendable {
        /// The network handler. The default is ``URLSessionTransport``.
        public var transport: any Transport = URLSessionTransport()

        /// The protocols offered during the handshake, most preferred first.
        /// The server picks one of them and the client speaks it for the rest
        /// of the connection.
        public var protocols: [any CableProtocol] = [V1JSON()]

        /// The headers sent on the upgrade request. An Action Cable server
        /// authorizes that request, so this is where a session cookie or a
        /// bearer token goes.
        public var headers: [String: String] = [:]

        /// Asked for headers on every dial rather than once. A client
        /// reconnects on its own for as long as it runs, which is longer than a
        /// credential that expires lives, and a reconnect carrying the token the
        /// first dial used would be turned down for good. What this returns is
        /// laid over ``headers``, so an origin or a token set there survives.
        ///
        /// An error turns down that dial, and the client tries again on its
        /// backoff. A `connect` that runs out of time or attempts meanwhile
        /// reports the error alongside its own, so a credential that can't be
        /// built doesn't hide behind a deadline.
        public var headerProvider: (@Sendable () async throws -> [String: String])?

        /// Recognizes connection errors that retrying cannot repair. It sees
        /// header, dial, and established-connection failures. When it returns
        /// true, the client stops with that error instead of reconnecting. It
        /// runs synchronously in the connection loop and must return promptly.
        public var stopOnError: (@Sendable (any Error) -> Bool)?

        /// Where the client's chatter goes. Nothing is logged by default.
        public var logger: (any CableLogger)?

        /// How long a connection may go without a frame before it counts as
        /// dead. The server beats every three seconds; the default is six, so
        /// two missed beats.
        public var staleAfter: TimeInterval = 6

        /// How often an unconfirmed subscribe command is resent. Half a second,
        /// like the JavaScript client's guarantor.
        public var subscribeRetry: TimeInterval = 0.5

        /// The first reconnect delay, doubled per failed attempt up to
        /// ``longestBackoff`` and spread with jitter.
        public var initialBackoff: TimeInterval = 1

        /// The longest a reconnect delay grows to.
        public var longestBackoff: TimeInterval = 30

        /// How many connection attempts may fail in a row before the client
        /// stops with ``ActionCableError/gaveUp(lastAttempt:)``. A welcome
        /// resets the count, so it bounds an outage rather than the client's
        /// lifetime. Zero, the default, keeps trying until `close`.
        public var maxAttempts: Int = 0

        /// How many messages a subscription buffers before it starts dropping
        /// them.
        public var messageBuffer: Int = 64

        public init() {}

        /// The `Cookie` header, for the common case of one.
        public var cookie: String? {
            get { header("Cookie") }
            set { setHeader("Cookie", to: newValue) }
        }

        /// The `Origin` header. Rails checks it unless the server disables
        /// request forgery protection, and assumes the cable URL's own origin
        /// when this is left alone.
        public var origin: String? {
            get { header("Origin") }
            set { setHeader("Origin", to: newValue) }
        }

        /// Offers protocols ahead of the ones already there, so preferring a
        /// new protocol doesn't mean restating the ones to fall back to.
        public mutating func addProtocols(_ added: [any CableProtocol]) {
            protocols = added + protocols
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        private mutating func setHeader(_ name: String, to value: String?) {
            for existing in headers.keys where existing.caseInsensitiveCompare(name) == .orderedSame {
                headers[existing] = nil
            }

            headers[name] = value
        }

        /// Fills in an `Origin` for the opening request when none was given.
        /// Rails compares `Origin` against the host it serves on and turns down
        /// anything else, a request carrying no `Origin` at all included, so the
        /// Action Cable URL's own origin is the one that gets in. A server
        /// behind a proxy that terminates TLS sees a different scheme than the
        /// URL says, and needs ``origin`` set to say so.
        func assumingOrigin(of url: String) -> [String: String] {
            if header("Origin") == nil, let assumed = originOf(url) {
                return headers.merging(["Origin": assumed]) { existing, _ in existing }
            } else {
                return headers
            }
        }
    }
}

func originOf(_ rawURL: String) -> String? {
    guard let components = URLComponents(string: rawURL), let host = components.host else {
        return nil
    }

    var authority = host
    if let port = components.port {
        authority += ":\(port)"
    }

    switch components.scheme?.lowercased() {
    case "wss", "https":
        return "https://" + authority
    case "ws", "http":
        return "http://" + authority
    default:
        return nil
    }
}
