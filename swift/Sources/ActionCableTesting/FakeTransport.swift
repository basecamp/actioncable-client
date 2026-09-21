import ActionCable
import Foundation

/// How long a fake waits for something that should already have happened.
public let fakeTransportTimeout: TimeInterval = 2

public enum FakeTransportError: Error, CustomStringConvertible {
    case noConnectionDialed
    case connectionDialed(subprotocol: String)
    case connectionClosed
    case nothingSent
    case somethingSent(String)
    case undecodable(String)
    case unexpectedCommand(expected: String, got: String)

    public var description: String {
        switch self {
        case .noConnectionDialed:
            return "no connection was dialed"
        case .connectionDialed(let subprotocol):
            return "expected no connection, got one with subprotocol \(subprotocol)"
        case .connectionClosed:
            return "the connection is closed"
        case .nothingSent:
            return "the client sent nothing"
        case .somethingSent(let payload):
            return "expected nothing to be sent, got \(payload)"
        case .undecodable(let payload):
            return "could not decode the command \(payload)"
        case .unexpectedCommand(let expected, let got):
            return "expected \(expected), got \(got)"
        }
    }
}

/// Hands out in-memory connections a test can play the server on.
public final class FakeTransport: Transport, @unchecked Sendable {
    /// What every connection reports the server picked.
    public var subprotocol: String {
        get { read { $0.subprotocol } }
        set { write { $0.subprotocol = newValue } }
    }

    /// How many commands a connection takes before a write waits on the test
    /// reading them. Zero makes every write wait, which lets a test hold the
    /// client mid-write.
    public var writeBuffer: Int {
        get { read { $0.writeBuffer } }
        set { write { $0.writeBuffer = newValue } }
    }

    /// The options the client last dialed with.
    public var dialedWith: DialOptions {
        read { $0.options }
    }

    private struct State {
        var subprotocol = Subprotocol.v1JSON
        var writeBuffer = 32
        var options = DialOptions()
        var refusals: [any Error] = []
    }

    private let mutex = NSLock()
    private var state = State()
    private let dialed = Channel<FakeConnection>(capacity: 16)

    public init() {}

    /// Turns the next dial down with this error, the way a refused connection
    /// would.
    public func failNextDial(_ error: any Error) {
        write { $0.refusals.append(error) }
    }

    public func dial(url: String, options: DialOptions) async throws -> any Connection {
        let refusal: (any Error)? = write { state in
            state.options = options

            if state.refusals.isEmpty {
                return nil
            } else {
                return state.refusals.removeFirst()
            }
        }

        if let refusal {
            throw refusal
        }

        let connection = read { FakeConnection(subprotocol: $0.subprotocol, writeBuffer: $0.writeBuffer) }
        await dialed.send(connection)

        return connection
    }

    /// Waits for the client to dial, and hands back the connection to play the
    /// server on.
    public func accept(timeout: TimeInterval = fakeTransportTimeout) async throws -> FakeConnection {
        if case .some(.value(let connection)) = try? await within(timeout, { await self.dialed.receive() }) {
            return connection
        } else {
            throw FakeTransportError.noConnectionDialed
        }
    }

    /// Fails when the client dials in the next little while.
    public func expectNoDial(within seconds: TimeInterval = 0.2) async throws {
        if case .some(.value(let connection)) = try? await within(seconds, { await self.dialed.receive() }) {
            throw FakeTransportError.connectionDialed(subprotocol: connection.subprotocol)
        }
    }

    private func read<T>(_ body: (State) -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }

        return body(state)
    }

    private func write<T>(_ body: (inout State) -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }

        return body(&state)
    }
}

/// One command the client sent, as it came off the wire.
public struct SentCommand: Codable, Sendable, Hashable {
    public let command: String
    public let identifier: String
    public let data: String?
}

/// One connection with the test playing the server on the other end.
///
/// Like Rails it keeps one subscription per identifier: a subscribe for an
/// identifier it has already heard, answered or not, is ignored.
public final class FakeConnection: Connection, @unchecked Sendable {
    public let subprotocol: String

    private let incoming = Channel<Data>()
    private let outgoing: Channel<Data>
    /// Ticks as each write begins, so a test can tell the client is stuck in
    /// one before anyone reads what it wrote.
    private let writing = Channel<Void>(capacity: 64)

    private let mutex = NSLock()
    private var subscribed: Set<String> = []
    private var closed = false

    init(subprotocol: String, writeBuffer: Int) {
        self.subprotocol = subprotocol
        outgoing = Channel<Data>(capacity: writeBuffer)
    }

    // MARK: - The client's side

    public func read() async throws -> Data {
        switch await incoming.receive() {
        case .value(let payload):
            return payload
        case .closed:
            throw FakeTransportError.connectionClosed
        case .cancelled:
            throw CancellationError()
        }
    }

    public func write(_ payload: Data) async throws {
        if ignores(payload) {
            return
        }

        writing.trySend(())

        if await outgoing.send(payload) {
            return
        } else if Task.isCancelled {
            throw CancellationError()
        } else {
            throw FakeTransportError.connectionClosed
        }
    }

    public func close() async {
        if firstClose() {
            incoming.close()
            outgoing.close()
            writing.close()
        }
    }

    private func firstClose() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        let first = !closed
        closed = true

        return first
    }

    // MARK: - The test's side

    /// Plays a server frame to the client, and waits for it to be read.
    public func push(_ frame: String) async throws {
        if await incoming.send(Data(frame.utf8)) {
            return
        } else {
            throw FakeTransportError.connectionClosed
        }
    }

    public func welcome() async throws {
        try await push(#"{"type":"welcome"}"#)
    }

    public func confirm(_ identifier: String) async throws {
        try await push(frame(type: "confirm_subscription", identifier: identifier))
    }

    /// Turns a subscription down, which also forgets it: the client is free to
    /// try again.
    public func reject(_ identifier: String) async throws {
        forget(identifier)

        try await push(frame(type: "reject_subscription", identifier: identifier))
    }

    private func forget(_ identifier: String) {
        mutex.lock()
        defer { mutex.unlock() }

        subscribed.remove(identifier)
    }

    /// Waits for the next payload the client writes, exactly as it went out.
    public func sent(timeout: TimeInterval = fakeTransportTimeout) async throws -> Data {
        if case .some(.value(let payload)) = try? await within(timeout, { await self.outgoing.receive() }) {
            return payload
        } else {
            throw FakeTransportError.nothingSent
        }
    }

    /// Waits for the next command the client sends. Nobody has heard it yet:
    /// ``command(timeout:)`` and ``dropCommand(_:_:timeout:)`` settle that.
    public func next(timeout: TimeInterval = fakeTransportTimeout) async throws -> SentCommand {
        let payload = try await sent(timeout: timeout)

        guard let command = try? JSONDecoder().decode(SentCommand.self, from: payload) else {
            throw FakeTransportError.undecodable(String(decoding: payload, as: UTF8.self))
        }

        return command
    }

    /// Waits for the next command the client sends and takes it in the way the
    /// server would.
    @discardableResult
    public func command(timeout: TimeInterval = fakeTransportTimeout) async throws -> SentCommand {
        let command = try await next(timeout: timeout)
        hear(command)

        return command
    }

    @discardableResult
    public func expectCommand(
        _ name: CommandName,
        _ identifier: String,
        timeout: TimeInterval = fakeTransportTimeout
    ) async throws -> SentCommand {
        let command = try await command(timeout: timeout)
        try expect(command, name, identifier)

        return command
    }

    /// Lets the next command fall on the floor, the way the server drops a
    /// subscribe that reaches it before the connection is set up.
    public func dropCommand(
        _ name: CommandName,
        _ identifier: String,
        timeout: TimeInterval = fakeTransportTimeout
    ) async throws {
        try expect(try await next(timeout: timeout), name, identifier)
    }

    /// Fails when the client sends anything in the next little while.
    public func expectNoCommand(within seconds: TimeInterval = 0.1) async throws {
        if case .some(.value(let payload)) = try? await within(seconds, { await self.outgoing.receive() }) {
            throw FakeTransportError.somethingSent(String(decoding: payload, as: UTF8.self))
        }
    }

    /// Waits for the client to begin a write, without reading what it wrote.
    public func beganWriting(timeout: TimeInterval = fakeTransportTimeout) async throws {
        if case .some(.value) = try? await within(timeout, { await self.writing.receive() }) {
            return
        } else {
            throw FakeTransportError.nothingSent
        }
    }

    // MARK: - Playing the server

    /// Whether the server would drop the command without a word: Rails does
    /// that to a second subscribe for an identifier the connection already has.
    private func ignores(_ payload: Data) -> Bool {
        guard let command = try? JSONDecoder().decode(SentCommand.self, from: payload) else {
            return false
        }

        mutex.lock()
        defer { mutex.unlock() }

        return command.command == CommandName.subscribe.rawValue && subscribed.contains(command.identifier)
    }

    private func hear(_ command: SentCommand) {
        mutex.lock()
        defer { mutex.unlock() }

        switch CommandName(rawValue: command.command) {
        case .subscribe:
            subscribed.insert(command.identifier)
        case .unsubscribe:
            subscribed.remove(command.identifier)
        default:
            break
        }
    }

    private func expect(_ command: SentCommand, _ name: CommandName, _ identifier: String) throws {
        if command.command != name.rawValue || command.identifier != identifier {
            throw FakeTransportError.unexpectedCommand(
                expected: "\(name.rawValue) \(identifier)",
                got: "\(command.command) \(command.identifier)"
            )
        }
    }

    private func frame(type: String, identifier: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(["type": type, "identifier": identifier])) ?? Data()

        return String(decoding: encoded, as: UTF8.self)
    }
}
