import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The built-in transport: `URLSessionWebSocketTask`, so the package carries no
/// dependencies. It negotiates the subprotocols it is handed, sends the headers
/// it is handed, refuses a non-101 upgrade as a ``HandshakeError``, never
/// follows a redirect, and reports a peer close as a ``CloseError``. Answering
/// pings and reassembling fragments are `URLSession`'s own job.
///
/// Three places where the platform can't do what Go's hand-written RFC 6455
/// client does are written up in the README: the reason phrase of a refused
/// upgrade, a close code outside the ones `URLSession` names, and refusing an
/// oversized message before it is read in.
public struct URLSessionTransport: Transport {
    /// Bounds the upgrade request.
    public var handshakeTimeout: TimeInterval

    /// Bounds a single write.
    public var writeTimeout: TimeInterval

    /// The largest message accepted, in bytes.
    public var maximumMessageSize: Int

    /// Builds the session each connection runs on, for a caller with its own
    /// TLS or proxy settings. The default is an ephemeral session, which keeps
    /// the shared cookie store and cache out of the upgrade request.
    public var session: @Sendable () -> URLSessionConfiguration

    public init(
        handshakeTimeout: TimeInterval = 10,
        writeTimeout: TimeInterval = 10,
        maximumMessageSize: Int = 8 << 20,
        session: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.writeTimeout = writeTimeout
        self.maximumMessageSize = maximumMessageSize
        self.session = session
    }

    public func dial(url: String, options: DialOptions) async throws -> any Connection {
        guard let endpoint = URL(string: url) else {
            throw URLError(.badURL)
        }

        let opener = Opener()
        let session = URLSession(configuration: session(), delegate: opener, delegateQueue: nil)
        let task = session.webSocketTask(with: request(for: endpoint, options: options))
        task.maximumMessageSize = maximumMessageSize
        task.resume()

        do {
            let subprotocol = try await withTimeout(handshakeTimeout) { try await opener.opened() }

            return WebSocketConnection(
                session: session,
                task: task,
                subprotocol: subprotocol,
                writeTimeout: writeTimeout,
                maximumMessageSize: maximumMessageSize
            )
        } catch {
            session.invalidateAndCancel()

            if error is TimedOut {
                throw URLError(.timedOut)
            } else {
                throw error
            }
        }
    }

    private func request(for endpoint: URL, options: DialOptions) -> URLRequest {
        var request = URLRequest(url: endpoint)

        // The client watches for a connection that has gone quiet itself, and
        // a cable that is only pinged every few seconds should not be torn down
        // by URLSession's own idle timeout first.
        request.timeoutInterval = 86400
        request.httpShouldHandleCookies = false

        for (name, value) in options.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("actioncable-swift", forHTTPHeaderField: "User-Agent")
        }
        if !options.subprotocols.isEmpty {
            request.setValue(options.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        return request
    }
}

/// Waits for the upgrade to land, and turns whatever happened instead into the
/// error a caller can act on. Afterwards it is the session's delegate for the
/// life of the connection, and lets the session go once its task is done.
private final class Opener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let mutex = NSLock()
    private var waiting: CheckedContinuation<String, any Error>?
    private var outcome: Result<String, any Error>?

    func opened() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            mutex.lock()

            if let outcome {
                mutex.unlock()
                continuation.resume(with: outcome)
            } else {
                waiting = continuation
                mutex.unlock()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol negotiated: String?
    ) {
        // Foundation on Linux reports an upgrade the server refused as an open
        // and only then fails the task, so the response has the last word.
        if let refusal = Self.refusal(from: webSocketTask.response) {
            settle(.failure(refusal))
        } else {
            settle(.success(negotiated ?? ""))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let refusal = Self.refusal(from: task.response) {
            settle(.failure(refusal))
        } else {
            settle(.failure(error ?? URLError(.badServerResponse)))
        }

        // The session is one connection's, so it goes when its task does. On
        // Apple platforms a cancel writes its close frame on the session's own
        // queue, and invalidating from the close itself could drop the socket
        // before the frame had left; from here, the frame is already out.
        session.finishTasksAndInvalidate()
    }

    /// Turns down every redirect. An Action Cable server that answers the
    /// upgrade with a 3xx is refusing it, and following the `Location` would
    /// carry the credentials somewhere they were never meant to go.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func settle(_ outcome: Result<String, any Error>) {
        mutex.lock()

        if self.outcome == nil {
            self.outcome = outcome
            let continuation = waiting
            waiting = nil
            mutex.unlock()

            continuation?.resume(with: outcome)
        } else {
            mutex.unlock()
        }
    }

    private static func refusal(from response: URLResponse?) -> HandshakeError? {
        guard let response = response as? HTTPURLResponse, response.statusCode != 101 else {
            return nil
        }

        return HandshakeError(statusCode: response.statusCode, status: status(response.statusCode))
    }

    /// `URLSession` keeps the status code but not the reason phrase the server
    /// wrote, so the phrase is the one Foundation knows for that code.
    private static func status(_ code: Int) -> String {
        "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
    }
}

private final class WebSocketConnection: StatusClosing, @unchecked Sendable {
    let subprotocol: String

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let writeTimeout: TimeInterval
    private let maximumMessageSize: Int

    private let mutex = NSLock()
    private var closed = false

    init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        subprotocol: String,
        writeTimeout: TimeInterval,
        maximumMessageSize: Int
    ) {
        self.session = session
        self.task = task
        self.subprotocol = subprotocol
        self.writeTimeout = writeTimeout
        self.maximumMessageSize = maximumMessageSize
    }

    func read() async throws -> Data {
        let payload: Data
        do {
            payload = Self.bytes(of: try await interruptible { try await self.task.receive() })
        } catch {
            throw failure(from: error)
        }

        // Foundation enforces `maximumMessageSize` on Apple platforms and not
        // on Linux, so the limit is checked here too and the answer is the same
        // on both. Go refuses the message before reading it in; this one is
        // already in memory by the time it is turned down.
        if payload.count > maximumMessageSize {
            await close()
            throw ActionCableError.messageTooBig
        }

        return payload
    }

    func write(_ payload: Data) async throws {
        do {
            try await withTimeout(writeTimeout) {
                try await self.interruptible {
                    try await self.task.send(.string(String(decoding: payload, as: UTF8.self)))
                }
            }
        } catch {
            throw failure(from: error)
        }
    }

    func close() async {
        await close(code: 1000, reason: "")
    }

    func close(code: Int, reason: String) async {
        if firstClose() {
            // The session is invalidated by its delegate once the task reports
            // itself done, not here: see Opener's didCompleteWithError.
            task.cancel(
                with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
                reason: Self.frameFitting(reason))
        }
    }

    private func firstClose() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        let first = !closed
        closed = true

        return first
    }

    /// Cancelling the task that is reading or writing has to interrupt it, and
    /// `URLSessionWebSocketTask` doesn't watch for that itself. Cancelling the
    /// socket ends the connection, which is what the client wants: a read it
    /// gave up waiting on is a connection it is about to redial.
    private func interruptible<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            task.cancel()
        }
    }

    private static func bytes(of message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return Data()
        }
    }

    private func failure(from error: any Error) -> any Error {
        if Task.isCancelled {
            return CancellationError()
        }

        if let urlError = error as? URLError, urlError.code == .dataLengthExceedsMaximum {
            return ActionCableError.messageTooBig
        }

        // Apple's URLSession refuses a message past `maximumMessageSize` with
        // the POSIX error a socket gives for the same thing, EMSGSIZE.
        if Self.isMessageTooLong(error) {
            return ActionCableError.messageTooBig
        }

        if task.closeCode != .invalid {
            return CloseError(
                code: task.closeCode.rawValue,
                reason: String(decoding: task.closeReason ?? Data(), as: UTF8.self)
            )
        }

        return error
    }

    private static func isMessageTooLong(_ error: any Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSPOSIXErrorDomain && failure.code == Int(EMSGSIZE)
    }

    /// As much of the reason as a control frame has room for: 125 bytes, less
    /// the two the code takes. The cut lands on a character boundary, so what
    /// goes out is always valid UTF-8.
    private static func frameFitting(_ reason: String) -> Data? {
        if reason.isEmpty {
            return nil
        }

        var fitting = reason
        while fitting.utf8.count > 123 {
            fitting.removeLast()
        }

        return Data(fitting.utf8)
    }
}
