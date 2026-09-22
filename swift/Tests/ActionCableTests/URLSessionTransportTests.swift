import ActionCable
import Foundation
import XCTest

final class URLSessionTransportTests: XCTestCase {
    private var server: LoopbackServer!

    private func start(_ handshake: LoopbackServer.Handshake = .upgrade) throws -> LoopbackServer {
        server = try LoopbackServer(handshake: handshake)

        return server
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil

        try await super.tearDown()
    }

    /// swift-corelibs-foundation hands each chunk libcurl gives it — 16 KiB at
    /// a time — to `receive()` as a message of its own, and does not reassemble
    /// a fragmented message either. Apple's `URLSession` reassembles both, and
    /// `receive()` is documented to. The README says where the two differ.
    private func skipWhereFoundationDoesNotReassemble() throws {
        #if !canImport(Darwin)
        throw XCTSkip(
            "swift-corelibs-foundation delivers a message larger than 16 KiB, or sent in fragments, in pieces")
        #endif
    }

    /// The half of a close the peer sees. On Apple platforms a
    /// `cancel(with:reason:)` ends the connection without the loopback peer
    /// ever reading a close frame — with or without a receive pending, and
    /// whether the session is invalidated at once or from the delegate — so
    /// what the frame carried cannot be asserted there. The README says so.
    private func skipWhereFoundationSendsNoCloseFrame() throws {
        #if canImport(Darwin)
        throw XCTSkip("Apple's URLSession closes the socket without a close frame the peer can read")
        #endif
    }

    private func dial(
        _ server: LoopbackServer,
        subprotocols: [String] = [],
        headers: [String: String] = [:],
        maximumMessageSize: Int = 8 << 20
    ) async throws -> any Connection {
        try await URLSessionTransport(maximumMessageSize: maximumMessageSize)
            .dial(url: server.url(), options: DialOptions(subprotocols: subprotocols, headers: headers))
    }

    func testWebSocketTransportNegotiatesTheSubprotocol() async throws {
        let server = try start()

        let connection = try await dial(server, subprotocols: [Subprotocol.v1JSON])
        let peer = try await server.accept()

        XCTAssertEqual(connection.subprotocol, Subprotocol.v1JSON)
        XCTAssertEqual(
            peer.request.headers["sec-websocket-protocol"],
            Subprotocol.v1JSON,
            "expected the client to offer the subprotocol"
        )

        await connection.close()
    }

    func testWebSocketTransportSendsHeaders() async throws {
        let server = try start()

        let connection = try await dial(
            server,
            subprotocols: [Subprotocol.v1JSON],
            headers: ["Cookie": "session=secret", "Origin": "https://example.com"]
        )
        let request = try await server.accept().request

        XCTAssertEqual(request.headers["cookie"], "session=secret")
        XCTAssertEqual(request.headers["origin"], "https://example.com")
        XCTAssertEqual(request.headers["user-agent"], "actioncable-swift")
        XCTAssertEqual(request.path, "/cable")

        await connection.close()
    }

    func testWebSocketTransportSendsTheCallersUserAgent() async throws {
        let server = try start()

        let connection = try await dial(server, headers: ["User-Agent": "custom-agent"])
        let request = try await server.accept().request

        XCTAssertEqual(request.headers["user-agent"], "custom-agent")

        await connection.close()
    }

    func testWebSocketTransportNeutralizesHeaderInjection() async throws {
        let server = try start()

        // Foundation may reject the header outright rather than sanitize it;
        // either way nothing injected is allowed to reach the server.
        let connection = try? await dial(
            server,
            headers: ["Authorization": "Bearer token\r\nX-Injected: gotcha"]
        )

        if let peer = try? await server.accept(timeout: 0.5) {
            XCTAssertNil(peer.request.headers["x-injected"], "expected the newlines to be neutralized")
        }

        await connection?.close()
    }

    func testWebSocketTransportRoundTripsMessages() async throws {
        let server = try start()
        let connection = try await dial(server, subprotocols: [Subprotocol.v1JSON])
        let peer = try await server.accept()

        try await connection.write(Data(#"{"command":"subscribe"}"#.utf8))
        let received = try await peer.read()
        XCTAssertEqual(received, #"{"command":"subscribe"}"#)

        try await peer.write(opText, #"{"type":"welcome"}"#)
        let payload = try await connection.read()
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), #"{"type":"welcome"}"#)

        await connection.close()
    }

    func testWebSocketTransportAnswersPings() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        try await peer.write(opPing, "beat")
        try await peer.write(opText, "after the ping")

        let payload = try await connection.read()
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "after the ping")

        let frame = try await peer.readFrame()
        XCTAssertEqual(frame.opcode, opPong, "expected a pong")
        XCTAssertEqual(frame.text, "beat", "expected the pong to carry the ping payload")

        await connection.close()
    }

    func testWebSocketTransportReassemblesFragments() async throws {
        try skipWhereFoundationDoesNotReassemble()

        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        try await peer.writeFragment(opText, Array("one ".utf8), final: false)
        try await peer.writeFragment(opPing, Array("interleaved".utf8), final: true)
        try await peer.writeFragment(opContinuation, Array("message".utf8), final: true)

        let payload = try await connection.read()
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "one message")

        await connection.close()
    }

    func testWebSocketTransportReadsLargeMessages() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        // The write half runs everywhere, so it goes first and the skip lands
        // between the two directions.
        let long = String(repeating: "cable", count: 30_000)
        try await connection.write(Data(long.utf8))
        let received = try await peer.read()
        XCTAssertEqual(received, long)

        try skipWhereFoundationDoesNotReassemble()

        try await peer.write(opText, long)
        let payload = try await connection.read()
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), long)

        await connection.close()
    }

    func testWebSocketTransportRefusesOversizedMessages() async throws {
        let server = try start()
        let connection = try await dial(server, maximumMessageSize: 8)
        let peer = try await server.accept()

        try await peer.write(opText, "far too long for eight bytes")

        await assertThrows(try await connection.read()) { assertCable($0, .messageTooBig) }

        await connection.close()
    }

    func testWebSocketTransportRefusesOversizedFragmentedMessages() async throws {
        try skipWhereFoundationDoesNotReassemble()

        let server = try start()
        let connection = try await dial(server, maximumMessageSize: 8)
        let peer = try await server.accept()

        try await peer.writeFragment(opText, Array("five ".utf8), final: false)
        try await peer.writeFragment(opContinuation, Array("more".utf8), final: true)

        await assertThrows(try await connection.read()) { assertCable($0, .messageTooBig) }

        await connection.close()
    }

    func testWebSocketTransportReportsServerClose() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        // 1008 rather than Go's 4401: `URLSessionWebSocketTask.CloseCode` names
        // the codes RFC 6455 reserves and nothing in the private-use range, so
        // an application's own code cannot survive the trip. The README says so.
        try await peer.write(opClose, closePayload(1008, "unauthorized"))

        await assertThrows(try await connection.read()) { error in
            XCTAssertEqual((error as? CloseError)?.code, 1008, "got \(error)")
            XCTAssertEqual((error as? CloseError)?.reason, "unauthorized")
        }

        await connection.close()
    }

    func testWebSocketTransportReportsAServerCloseWithoutAStatus() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        try await peer.write(opClose, [])

        #if !canImport(Darwin)
        throw XCTSkip("swift-corelibs-foundation reports a close frame with no code as 1000 rather than 1005")
        #endif

        await assertThrows(try await connection.read()) { error in
            XCTAssertEqual((error as? CloseError)?.code, 1005, "got \(error)")
            XCTAssertEqual((error as? CloseError)?.reason, "")
        }

        await connection.close()
    }

    func testWebSocketTransportClosesWithAStatus() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        let closer = try XCTUnwrap(connection as? StatusClosing, "the built-in connection should be a StatusClosing")
        await closer.close(code: 1008, reason: "done here")

        try skipWhereFoundationSendsNoCloseFrame()

        let frame = try await peer.readFrame()
        XCTAssertEqual(frame.opcode, opClose)
        XCTAssertEqual(closeCode(of: frame), 1008)
        XCTAssertEqual(String(decoding: frame.payload.dropFirst(2), as: UTF8.self), "done here")
    }

    func testWebSocketTransportTruncatesACloseReasonToFitTheFrame() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        let closer = try XCTUnwrap(connection as? StatusClosing)
        await closer.close(code: 1008, reason: String(repeating: "r", count: 200))

        try skipWhereFoundationSendsNoCloseFrame()

        let frame = try await peer.readFrame()
        XCTAssertEqual(frame.opcode, opClose)
        XCTAssertEqual(frame.payload.count, 125, "a control frame's payload is at most 125 bytes")
    }

    func testWebSocketTransportRefusesANonUpgradeResponse() async throws {
        let server = try start(.refuse(status: 404, phrase: "Not Found"))

        await assertThrows(try await dial(server)) { error in
            XCTAssertEqual(
                (error as? HandshakeError)?.statusCode,
                404,
                "expected a HandshakeError for a server that refuses to upgrade, got \(error)"
            )
        }
    }

    func testWebSocketTransportDoesNotFollowARedirect() async throws {
        let server = try start(.redirect)

        await assertThrows(try await dial(server)) { error in
            XCTAssertEqual(
                (error as? HandshakeError)?.statusCode,
                302,
                "expected a HandshakeError for a redirect, got \(error)"
            )
        }
    }

    func testWebSocketTransportRefusesABadAcceptKey() async throws {
        #if !canImport(Darwin)
        throw XCTSkip("swift-corelibs-foundation accepts an upgrade whose Sec-WebSocket-Accept is wrong")
        #endif

        let server = try start(.badAccept)

        await assertThrows(try await dial(server)) { _ in }
    }

    func testWebSocketTransportHonorsContextCancellation() async throws {
        let server = try start()
        let connection = try await dial(server)
        _ = try await server.accept()

        let reading = Task { try await connection.read() }
        try await Task.sleep(nanoseconds: 50_000_000)
        reading.cancel()

        await assertThrows(try await reading.value) { _ in }

        await connection.close()
    }

    /// Runs the whole cable dance over an actual WebSocket connection.
    func testClientOverTheRealTransport() async throws {
        let server = try start()
        let client = ActionCableClient(url: server.url())

        let connecting = connecting(client)
        let peer = try await server.accept()
        try await peer.write(opText, #"{"type":"welcome"}"#)
        try await connecting.value

        let subscribing = subscribing(client, room())
        let subscribe = try await peer.read()
        XCTAssertEqual(subscribe, #"{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}"}"#)
        try await peer.write(
            opText, #"{"type":"confirm_subscription","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}"}"#)

        let subscription = try await subscribing.value
        let messages = MessageLog(subscription)

        try await peer.write(
            opText,
            #"{"identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","message":{"body":"Hello!"}}"#
        )
        await expectMessage(messages, #"{"body":"Hello!"}"#)

        try await subscription.perform("speak", data: ["body": "Hi!"])
        let performed = try await peer.read()
        XCTAssertEqual(
            performed,
            #"{"command":"message","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","data":"{\"action\":\"speak\",\"body\":\"Hi!\"}"}"#
        )

        await client.close()
    }

    func testWebSocketTransportRefusesAMaskedServerFrame() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        // RFC 6455 §5.1: a server must never mask, and a client that sees a
        // masked frame must fail the connection rather than quietly unmask it.
        try await peer.writeMasked(opText, Array(#"{"type":"welcome"}"#.utf8))

        await assertThrows(try await connection.read()) { _ in }

        await connection.close()
    }

    func testWebSocketTransportRepliesToACloseOnce() async throws {
        let server = try start()
        let connection = try await dial(server)
        let peer = try await server.accept()

        try await peer.write(opClose, closePayload(1000))
        await assertThrows(try await connection.read()) { _ in }
        await connection.close()

        let closes = try await peer.closeFrames(timeout: 0.5)
        XCTAssertEqual(closes, 1, "expected exactly one close frame in reply")
    }
}
