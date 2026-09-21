import ActionCable
import ActionCableTesting
import Foundation
import XCTest

/// How long a test will hang around for something that should already have
/// happened.
let wait: TimeInterval = 2

let roomIdentifier = #"{"channel":"RoomChannel","id":42}"#
let otherIdentifier = #"{"channel":"OtherChannel"}"#

func room() -> Identifier {
    Identifier(channel: "RoomChannel", params: ["id": 42])
}

func newTestClient(
    _ transport: any Transport,
    url: String = "ws://cable.example.com/cable",
    _ configure: (inout ActionCableClient.Configuration) -> Void = { _ in }
) -> ActionCableClient {
    var configuration = ActionCableClient.Configuration()
    configuration.transport = transport
    configuration.logger = RecordingLogger()
    configure(&configuration)

    return ActionCableClient(url: url, configuration: configuration)
}

extension ActionCableClient.Configuration {
    /// Redials at once, so a test doesn't wait out a backoff.
    mutating func reconnectImmediately() {
        initialBackoff = 0.001
        longestBackoff = 0.001
    }
}

func connecting(_ client: ActionCableClient) -> Task<Void, any Error> {
    Task { try await client.connect() }
}

/// Connects a client and plays the server's welcome, returning the connection
/// the test can go on talking over.
func welcomed(_ client: ActionCableClient, _ transport: FakeTransport) async throws -> FakeConnection {
    let connecting = connecting(client)
    let connection = try await transport.accept()
    try await connection.welcome()
    try await connecting.value

    return connection
}

/// Subscribes in the background, since `subscribe` waits for the confirmation
/// the test still has to send.
func subscribing(
    _ client: ActionCableClient,
    _ identifier: Identifier,
    onConnected: (@Sendable (Bool) async -> Void)? = nil,
    onDisconnected: (@Sendable (Bool) async -> Void)? = nil,
    onRejected: (@Sendable () async -> Void)? = nil
) -> Task<Subscription, any Error> {
    Task {
        try await client.subscribe(
            to: identifier,
            onConnected: onConnected,
            onDisconnected: onDisconnected,
            onRejected: onRejected
        )
    }
}

func subscribed(_ client: ActionCableClient, _ connection: FakeConnection) async throws -> Subscription {
    let subscribing = subscribing(client, room())
    try await connection.expectCommand(.subscribe, roomIdentifier)
    try await connection.confirm(roomIdentifier)

    return try await subscribing.value
}

/// Takes the client's chatter so the logging paths run during the tests, and
/// keeps it for a test that wants to read it.
final class RecordingLogger: CableLogger, @unchecked Sendable {
    private let mutex = NSLock()
    private var lines: [String] = []

    func log(_ message: String) {
        mutex.lock()
        defer { mutex.unlock() }

        lines.append(message)
    }

    var messages: [String] {
        mutex.lock()
        defer { mutex.unlock() }

        return lines
    }
}

/// Drains a subscription's messages into a queue a test can poll.
///
/// Cancelling a task that is awaiting the next element of an `AsyncStream`
/// ends the stream, so a test can't race a read against a timeout — one
/// reader takes everything, and the test asks this what arrived.
final class MessageLog: @unchecked Sendable {
    enum Next: Sendable {
        case message(Message)
        case ended
        case nothing
    }

    private let mutex = NSLock()
    private var queue: [Message] = []
    private var ended = false

    init(_ subscription: Subscription) {
        let messages = subscription.messages

        Task { [self] in
            for await message in messages {
                append(message)
            }

            finish()
        }
    }

    func next(within seconds: TimeInterval = wait) async -> Next {
        let deadline = Date().addingTimeInterval(seconds)

        while true {
            if let next = take() {
                return next
            }
            if Date() >= deadline {
                return .nothing
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func take() -> Next? {
        mutex.lock()
        defer { mutex.unlock() }

        if !queue.isEmpty {
            return .message(queue.removeFirst())
        } else if ended {
            return .ended
        } else {
            return nil
        }
    }

    private func append(_ message: Message) {
        mutex.lock()
        defer { mutex.unlock() }

        queue.append(message)
    }

    private func finish() {
        mutex.lock()
        defer { mutex.unlock() }

        ended = true
    }
}

func expectMessage(
    _ log: MessageLog,
    _ expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    switch await log.next() {
    case .message(let message):
        XCTAssertEqual(message.text, expected, file: file, line: line)
    case .ended:
        XCTFail("the message stream ended before \(expected) arrived", file: file, line: line)
    case .nothing:
        XCTFail("no message arrived", file: file, line: line)
    }
}

func expectStreamEnded(_ log: MessageLog, file: StaticString = #filePath, line: UInt = #line) async {
    switch await log.next() {
    case .message(let message):
        XCTFail("the message stream is still delivering: \(message)", file: file, line: line)
    case .ended:
        return
    case .nothing:
        XCTFail("the message stream never ended", file: file, line: line)
    }
}

/// A thread-safe box for what a callback saw, since a callback runs on a task
/// of its own.
final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let mutex = NSLock()
    private var values: [Value] = []

    func record(_ value: Value) {
        mutex.lock()
        defer { mutex.unlock() }

        values.append(value)
    }

    var all: [Value] {
        mutex.lock()
        defer { mutex.unlock() }

        return values
    }

    var count: Int {
        all.count
    }

    /// The next value the callback recorded, or nil if none arrived in time.
    func next(within seconds: TimeInterval = wait) async -> Value? {
        let deadline = Date().addingTimeInterval(seconds)

        while true {
            if let value = take() {
                return value
            }
            if Date() >= deadline {
                return nil
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func take() -> Value? {
        mutex.lock()
        defer { mutex.unlock() }

        if values.isEmpty {
            return nil
        } else {
            return values.removeFirst()
        }
    }
}

/// Encodes to nothing at all, for the tests about data that can't be encoded.
struct Unencodable: Encodable {
    struct Refused: Error {}

    func encode(to encoder: any Encoder) throws {
        throw Refused()
    }
}

/// An error a test can recognize on the way back out.
struct TestError: Error, Equatable {
    let what: String
}

func assertThrows<T>(
    _ operation: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (any Error) -> Void
) async {
    do {
        _ = try await operation()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}

/// Names the cases of ``ActionCableError`` so a test can say which one it
/// wanted without a `switch` around every assertion. Go matches these with
/// `errors.Is`.
enum CableErrorLabel: String {
    case closed
    case notConnected
    case rejected
    case unsupportedSubprotocol
    case alreadyConnected
    case noProtocols
    case gaveUp
    case unsubscribed
    case messageTooBig
    case connectCancelled
    case connectionWentQuiet
    case unencodableIdentifier
    case unencodableData
    case dataIsNotAnObject
}

extension ActionCableError {
    var label: CableErrorLabel {
        switch self {
        case .closed: return .closed
        case .notConnected: return .notConnected
        case .rejected: return .rejected
        case .unsupportedSubprotocol: return .unsupportedSubprotocol
        case .alreadyConnected: return .alreadyConnected
        case .noProtocols: return .noProtocols
        case .gaveUp: return .gaveUp
        case .unsubscribed: return .unsubscribed
        case .messageTooBig: return .messageTooBig
        case .connectCancelled: return .connectCancelled
        case .connectionWentQuiet: return .connectionWentQuiet
        case .unencodableIdentifier: return .unencodableIdentifier
        case .unencodableData: return .unencodableData
        case .dataIsNotAnObject: return .dataIsNotAnObject
        }
    }
}

func assertCable(
    _ error: (any Error)?,
    _ expected: CableErrorLabel,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        (error as? ActionCableError)?.label, expected, "\(message) (got \(error as Any))", file: file, line: line)
}

/// Whether the client stops for good in time. Go waits on its `Done` channel.
func stopped(_ client: ActionCableClient, within seconds: TimeInterval = wait) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await client.waitUntilDone()
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }

        defer { group.cancelAll() }

        return await group.next()!
    }
}

/// Closes every client a test opened, so nothing is left dialing behind it.
class CableTestCase: XCTestCase {
    private let opened = Recorded<ActionCableClient>()

    func newClient(
        _ transport: any Transport,
        url: String = "ws://cable.example.com/cable",
        _ configure: (inout ActionCableClient.Configuration) -> Void = { _ in }
    ) -> ActionCableClient {
        let client = newTestClient(transport, url: url, configure)
        opened.record(client)

        return client
    }

    override func tearDown() async throws {
        for client in opened.all {
            await client.close()
        }

        try await super.tearDown()
    }
}
