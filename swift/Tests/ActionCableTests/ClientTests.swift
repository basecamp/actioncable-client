import ActionCable
import ActionCableTesting
import Foundation
import XCTest

final class ClientTests: CableTestCase {
    func testConnectWaitsForTheWelcome() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)

        let returned = Recorded<Bool>()
        let connecting = Task {
            try await client.connect()
            returned.record(true)
        }
        let connection = try await transport.accept()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(returned.count, 0, "connect returned before the welcome")

        try await connection.welcome()
        try await connecting.value
        let connected = await client.isConnected
        XCTAssertTrue(connected, "client is not connected after the welcome")
    }

    func testConnectRetriesUntilTheServerAnswers() async throws {
        let transport = FakeTransport()
        transport.failNextDial(TestError(what: "connection refused"))
        let client = newClient(transport) { $0.reconnectImmediately() }

        let connecting = connecting(client)
        try await transport.accept().welcome()

        try await connecting.value
    }

    func testSubscribeReceivesMessages() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let connections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onConnected: { connections.record($0) })

        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)

        let subscription = try await subscribing.value
        let messages = MessageLog(subscription)
        let reconnected = await connections.next()
        XCTAssertEqual(reconnected, false, "first connection reported itself as a reconnect")

        try await connection.push(
            #"{"identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","message":{"body":"Hello!"}}"#)

        switch await messages.next() {
        case .message(let message):
            XCTAssertEqual(try message.decode(Said.self).body, "Hello!")
        default:
            XCTFail("no message arrived")
        }
    }

    func testSubscribeRejected() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let rejections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onRejected: { rejections.record(true) })

        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.reject(roomIdentifier)

        await assertThrows(try await subscribing.value) { assertCable($0, .rejected) }
        let called = await rejections.next()
        XCTAssertEqual(called, true, "onRejected was never called")
    }

    func testPerformSendsAnAction() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        try await subscription.perform("speak", data: ["body": "Hello!"])

        let command = try await connection.expectCommand(.message, roomIdentifier)
        XCTAssertEqual(command.data, #"{"action":"speak","body":"Hello!"}"#, "expected the action alongside the data")
    }

    func testSendDeliversDataWithoutAnAction() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        try await subscription.send(["body": "Hello!"])

        let command = try await connection.expectCommand(.message, roomIdentifier)
        XCTAssertEqual(command.data, #"{"body":"Hello!"}"#, "expected the data on its own")
    }

    func testSendRefusesDataThatCannotEncode() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        await assertThrows(try await subscription.send(Unencodable())) {
            assertCable($0, .unencodableData, "expected an error for a payload that can't encode")
        }
    }

    func testPerformRefusesDataThatIsNotAnObject() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        await assertThrows(try await subscription.perform("speak", data: ["nope"])) {
            assertCable($0, .dataIsNotAnObject, "expected an error for a non-object payload")
        }
    }

    func testUnsubscribeClosesMessagesAndTellsTheServer() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)
        let messages = MessageLog(subscription)

        try await subscription.unsubscribe()
        try await connection.expectCommand(.unsubscribe, roomIdentifier)

        await expectStreamEnded(messages)
    }

    func testReconnectResubscribes() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        let connections = Recorded<Bool>()
        let disconnections = Recorded<Bool>()
        let subscribing = subscribing(
            client,
            room(),
            onConnected: { connections.record($0) },
            onDisconnected: { disconnections.record($0) }
        )
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value
        _ = await connections.next()

        await connection.close()

        let willReconnect = await disconnections.next()
        XCTAssertEqual(willReconnect, true, "disconnect reported that the client would not reconnect")

        let reconnected = try await transport.accept()
        try await reconnected.welcome()
        try await reconnected.expectCommand(.subscribe, roomIdentifier)
        try await reconnected.confirm(roomIdentifier)

        let wasReconnect = await connections.next()
        XCTAssertEqual(wasReconnect, true, "expected the confirmation after a reconnect to report reconnected")
    }

    func testStaleConnectionIsReplaced() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) {
            $0.staleAfter = 0.075
            $0.reconnectImmediately()
        }

        let connecting = connecting(client)
        try await transport.accept().welcome()
        try await connecting.value

        // Say nothing at all: no pings, no messages. The connection goes stale.
        try await transport.accept().welcome()
    }

    func testUnconfirmedSubscribeIsRetried() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.subscribeRetry = 0.02 }
        let connection = try await welcomed(client, transport)

        let subscribing = subscribing(client, room())
        try await connection.dropCommand(.subscribe, roomIdentifier)
        try await connection.expectCommand(.subscribe, roomIdentifier)

        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value
    }

    func testServerDisconnectWithoutReconnectStopsTheClient() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        try await connection.push(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)

        try await transport.expectNoDial()
        let connected = await client.isConnected
        XCTAssertFalse(connected, "client is still connected after being told to go away")

        await assertThrows(try await client.subscribe(to: room())) { error in
            XCTAssertEqual((error as? DisconnectError)?.reason, .unauthorized)
        }
    }

    func testServerDisconnectWithReconnectDialsAgain() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        try await connection.push(#"{"type":"disconnect","reason":"server_restart","reconnect":true}"#)

        try await transport.accept().welcome()
    }

    func testClientOffersEveryProtocolAndTheSentinel() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) {
            $0.protocols = [V1JSON(), FakeProtocol(subprotocol: "actioncable-v2-json", stamp: "v2:")]
        }

        _ = try await welcomed(client, transport)

        XCTAssertEqual(
            transport.dialedWith.subprotocols,
            [Subprotocol.v1JSON, "actioncable-v2-json", Subprotocol.unsupported]
        )
    }

    func testAdditionalProtocolsAreOfferedFirst() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) {
            $0.addProtocols([FakeProtocol(subprotocol: "actioncable-v2-json", stamp: "v2:")])
        }

        _ = try await welcomed(client, transport)

        XCTAssertEqual(
            transport.dialedWith.subprotocols,
            ["actioncable-v2-json", Subprotocol.v1JSON, Subprotocol.unsupported]
        )
    }

    func testClientSpeaksTheProtocolTheServerPicked() async throws {
        let transport = FakeTransport()
        transport.subprotocol = "actioncable-v2-json"
        let client = newClient(transport) {
            $0.protocols = [V1JSON(), FakeProtocol(subprotocol: "actioncable-v2-json", stamp: "v2:")]
        }

        let connection = try await welcomed(client, transport)
        _ = subscribing(client, room())

        let sent = String(decoding: try await connection.sent(), as: UTF8.self)
        XCTAssertTrue(
            sent.hasPrefix("v2:"),
            "expected the negotiated protocol to encode the subscribe, got \(sent)"
        )
    }

    func testUnsupportedSentinelStopsTheClient() async throws {
        let transport = FakeTransport()
        transport.subprotocol = Subprotocol.unsupported
        let client = newClient(transport) { $0.reconnectImmediately() }

        await assertThrows(try await client.connect()) { assertCable($0, .unsupportedSubprotocol) }

        _ = try await transport.accept()
        try await transport.expectNoDial()
    }

    func testNoProtocolsStopsTheClient() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.protocols = [] }

        await assertThrows(try await client.connect()) { assertCable($0, .noProtocols) }

        try await transport.expectNoDial()
    }

    func testUnsupportedSubprotocolStopsTheClient() async throws {
        let transport = FakeTransport()
        transport.subprotocol = "actioncable-v9-telepathy"
        let client = newClient(transport) { $0.reconnectImmediately() }

        await assertThrows(try await client.connect()) { assertCable($0, .unsupportedSubprotocol) }

        _ = try await transport.accept()
        try await transport.expectNoDial()
    }

    func testSubscribeBeforeConnect() async throws {
        let client = newClient(FakeTransport())

        await assertThrows(try await client.subscribe(to: room())) { assertCable($0, .notConnected) }
    }

    func testCloseClosesSubscriptions() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)
        let messages = MessageLog(subscription)

        await client.close()

        await expectStreamEnded(messages)
        await assertThrows(try await subscription.perform("speak")) {
            assertCable($0, .notConnected, "after close")
        }
    }

    func testMessagesArriveOnEverySubscriptionSharingAnIdentifier() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let first = try await subscribed(client, connection)
        let second = try await client.subscribe(to: room())
        let firstMessages = MessageLog(first)
        let secondMessages = MessageLog(second)

        try await connection.push(
            #"{"identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","message":{"body":"Hello!"}}"#)

        await expectMessage(firstMessages, #"{"body":"Hello!"}"#)
        await expectMessage(secondMessages, #"{"body":"Hello!"}"#)

        // Only the last subscription standing tells the server to unsubscribe.
        try await first.unsubscribe()
        try await connection.expectNoCommand()

        try await second.unsubscribe()
        try await connection.expectCommand(.unsubscribe, roomIdentifier)
    }

    func testSubscribeToAConfirmedIdentifierSendsNothing() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        _ = try await subscribed(client, connection)

        // Rails has the identifier already and would ignore a second subscribe,
        // so the one confirmation it gave stands for this subscription too.
        let connections = Recorded<Bool>()
        _ = try await client.subscribe(to: room(), onConnected: { connections.record($0) })

        let reconnected = await connections.next()
        XCTAssertEqual(
            reconnected, false, "a subscription joining a confirmed identifier reported itself as a reconnect")
        try await connection.expectNoCommand()
    }

    func testSubscribersJoinAnInFlightSubscribe() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let first = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)
        let second = subscribing(client, room())
        let third = subscribing(client, room())
        try await connection.expectNoCommand()

        try await connection.confirm(roomIdentifier)

        for subscribing in [first, second, third] {
            _ = try await subscribing.value
        }
    }

    func testSubscribersJoiningAnInFlightSubscribeShareItsRejection() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let first = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)
        let second = subscribing(client, room())
        try await connection.expectNoCommand()

        try await connection.reject(roomIdentifier)

        await assertThrows(try await first.value) { assertCable($0, .rejected) }
        await assertThrows(try await second.value) { assertCable($0, .rejected) }
    }

    func testSubscribersJoiningAnInFlightSubscribeFollowItThroughAReconnect() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        let first = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)
        let second = subscribing(client, room())
        try await connection.expectNoCommand()

        await connection.close()

        let reconnected = try await transport.accept()
        try await reconnected.welcome()
        try await reconnected.expectCommand(.subscribe, roomIdentifier)
        try await reconnected.expectNoCommand()
        try await reconnected.confirm(roomIdentifier)

        _ = try await first.value
        _ = try await second.value
    }

    func testCancellingTheOnlyInFlightSubscribeTellsTheServer() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let subscribing = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)

        // The server has the subscription whether or not anyone here still
        // wants it, and would ignore the next subscribe for it unless told to
        // let go.
        subscribing.cancel()
        await assertThrows(try await subscribing.value) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        try await connection.expectCommand(.unsubscribe, roomIdentifier)
        try await connection.expectNoCommand()

        _ = try await subscribed(client, connection)
    }

    func testCancellingASubscriberJoiningAnInFlightSubscribeLeavesTheFirstWaiting() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let first = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)

        let joining = subscribing(client, room())
        try await connection.expectNoCommand()

        joining.cancel()
        await assertThrows(try await joining.value) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        try await connection.expectNoCommand()

        try await connection.confirm(roomIdentifier)
        _ = try await first.value
    }

    func testConnectAfterCloseReportsWhyItStopped() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        _ = try await welcomed(client, transport)

        await client.close()

        await assertThrows(try await client.connect()) { assertCable($0, .closed) }
        try await transport.expectNoDial()
    }

    func testCloseBeforeConnectLeavesTheClientDead() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)

        await client.close()

        await assertThrows(try await client.connect()) { assertCable($0, .closed) }
        let connected = await client.isConnected
        XCTAssertFalse(connected, "a client closed before it started reports itself connected")
        try await transport.expectNoDial()
    }

    func testCloseFromOnDisconnected() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        let closings = Recorded<Bool>()
        let subscribing = subscribing(
            client,
            room(),
            onDisconnected: { _ in
                await client.close()
                closings.record(true)
            }
        )
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value

        await connection.close()

        let closed = await closings.next()
        XCTAssertEqual(closed, true, "close from onDisconnected never returned")
    }

    func testSubscribeFromOnConnected() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let subscribing = subscribing(
            client,
            room(),
            onConnected: { _ in
                Task {
                    _ = try? await client.subscribe(to: Identifier(channel: "OtherChannel"))
                }
            }
        )
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value

        try await connection.expectCommand(.subscribe, otherIdentifier)
        try await connection.confirm(otherIdentifier)
    }

    func testUnsubscribeWhileMessagesArrive() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.messageBuffer = 1 }
        let connection = try await welcomed(client, transport)

        for _ in 0..<50 {
            let subscription = try await subscribed(client, connection)

            let pushing = Task {
                try? await connection.push(
                    #"{"identifier":"{\"channel\":\"RoomChannel\",\"id\":42}","message":{"body":"Hello!"}}"#
                )
            }

            try await subscription.unsubscribe()
            await pushing.value
            try await connection.expectCommand(.unsubscribe, roomIdentifier)
        }
    }

    func testFirstConnectionIsNotAReconnect() async throws {
        let transport = FakeTransport()
        transport.failNextDial(TestError(what: "connection refused"))
        let client = newClient(transport) { $0.reconnectImmediately() }

        let connecting = connecting(client)
        let connection = try await transport.accept()
        try await connection.welcome()
        try await connecting.value

        let connections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onConnected: { connections.record($0) })
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value

        let reconnected = await connections.next()
        XCTAssertEqual(reconnected, false, "a first connection that took two dials reported itself as a reconnect")
    }

    func testPerformBeforeTheWelcomeIsRefused() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        await connection.close()
        _ = try await transport.accept()

        // The connection is up again but not yet welcomed, and the server
        // throws away anything sent that early, so a command then is not a
        // command landed.
        await assertThrows(try await subscription.perform("speak")) { assertCable($0, .notConnected) }
    }

    func testRepeatedConfirmationConnectsOnce() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let connections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onConnected: { connections.record($0) })
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value
        _ = await connections.next()

        try await connection.confirm(roomIdentifier)

        let second = await connections.next(within: 0.1)
        XCTAssertNil(second, "a second confirmation reported a second connection")
    }

    func testOriginDefaultsToTheCableURL() async throws {
        let urls = [
            "wss://cable.example.com/cable": "https://cable.example.com",
            "ws://cable.example.com:3000/cable": "http://cable.example.com:3000",
            "wss://cable.example.com:8443/cable": "https://cable.example.com:8443",
        ]

        // Rails compares Origin against the host it serves on, and turns down a
        // request that carries no Origin at all.
        for (url, origin) in urls {
            let transport = FakeTransport()
            let client = newClient(transport, url: url)

            let connecting = connecting(client)
            try await transport.accept().welcome()
            try await connecting.value

            XCTAssertEqual(transport.dialedWith.headers["Origin"], origin, url)
        }
    }

    func testExplicitOriginWins() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.origin = "https://app.example.com" }

        let connecting = connecting(client)
        try await transport.accept().welcome()
        try await connecting.value

        XCTAssertEqual(
            transport.dialedWith.headers["Origin"],
            "https://app.example.com",
            "expected the origin given"
        )
    }

    func testHeaderIsCopied() async throws {
        let transport = FakeTransport()
        var headers = ["Cookie": "session=secret"]
        let client = newClient(transport) { $0.headers = headers }

        headers["Cookie"] = "session=tampered"

        let connecting = connecting(client)
        try await transport.accept().welcome()
        try await connecting.value

        XCTAssertEqual(
            transport.dialedWith.headers["Cookie"],
            "session=secret",
            "expected the header as it was given"
        )
    }

    func testEveryDialAsksForTheHeaderAgain() async throws {
        let transport = FakeTransport()
        transport.failNextDial(TestError(what: "connection refused"))

        let dials = Counter()
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.headers = ["Origin": "https://app.example.com"]
            $0.headerProvider = { ["Authorization": "Bearer token-\(dials.next())"] }
        }

        let connecting = connecting(client)
        try await transport.accept().welcome()
        try await connecting.value

        let dialed = transport.dialedWith.headers
        XCTAssertEqual(
            dialed["Authorization"],
            "Bearer token-2",
            "expected the redial to carry the credentials it asked for then"
        )
        XCTAssertEqual(dialed["Origin"], "https://app.example.com", "expected the headers set once to survive")
    }

    func testATerminalDialErrorStopsTheInitialConnection() async throws {
        let transport = FakeTransport()
        let denied = TestError(what: "connection denied")
        transport.failNextDial(denied)
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.stopOnError = { ($0 as? TestError) == denied }
        }

        await assertThrows(try await client.connect()) { XCTAssertEqual($0 as? TestError, denied) }
        let failure = await client.error
        XCTAssertEqual(failure as? TestError, denied)
        try await transport.expectNoDial()
    }

    func testANonTerminalConnectionErrorStillReconnects() async throws {
        let transport = FakeTransport()
        let signedOut = TestError(what: "sign in again")
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.stopOnError = { ($0 as? TestError) == signedOut }
        }
        let connection = try await welcomed(client, transport)

        await connection.close()
        try await transport.accept().welcome()

        let failure = await client.error
        XCTAssertNil(failure, "a retryable error stopped the client")
    }

    func testATerminalConnectionErrorStopsSubscriptions() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.stopOnError = { ($0 as? FakeTransportError) != nil }
        }
        let connection = try await welcomed(client, transport)

        let disconnections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onDisconnected: { disconnections.record($0) })
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        let subscription = try await subscribing.value
        let messages = MessageLog(subscription)

        await connection.close()

        let willReconnect = await disconnections.next()
        XCTAssertEqual(willReconnect, false, "onDisconnected promised a reconnect after a terminal error")

        let done = await stopped(client)
        XCTAssertTrue(done, "client kept reconnecting after the terminal connection error")

        let failure = await client.error
        XCTAssertTrue(failure is FakeTransportError, "got \(failure as Any)")
        await expectStreamEnded(messages)
        XCTAssertTrue(subscription.error is FakeTransportError, "got \(subscription.error as Any)")
        try await transport.expectNoDial()
    }

    func testATerminalHeaderErrorStopsTheInitialConnection() async throws {
        let transport = FakeTransport()
        let signedOut = TestError(what: "sign in again")
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.stopOnError = { ($0 as? TestError) == signedOut }
            $0.headerProvider = { throw signedOut }
        }

        await assertThrows(try await client.connect()) { XCTAssertEqual($0 as? TestError, signedOut) }
        let failure = await client.error
        XCTAssertEqual(failure as? TestError, signedOut)
        try await transport.expectNoDial()
    }

    func testATerminalHeaderErrorStopsAReconnect() async throws {
        let transport = FakeTransport()
        let signedOut = TestError(what: "sign in again")
        let headers = Counter()
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.stopOnError = { ($0 as? TestError) == signedOut }
            $0.headerProvider = {
                if headers.next() == 1 {
                    return ["Authorization": "Bearer token"]
                } else {
                    throw signedOut
                }
            }
        }

        let connection = try await welcomed(client, transport)
        await connection.close()

        let done = await stopped(client)
        XCTAssertTrue(done, "client kept reconnecting after the terminal header error")

        let failure = await client.error
        XCTAssertEqual(failure as? TestError, signedOut)
        XCTAssertEqual(headers.count, 2, "expected one initial header and one failed reconnect header")
        try await transport.expectNoDial()
    }

    func testADialIsTurnedDownWhenTheHeaderCannotBeBuilt() async throws {
        let transport = FakeTransport()
        let asked = Counter()
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.headerProvider = {
                if asked.next() == 1 {
                    throw TestError(what: "no credentials to hand over")
                } else {
                    return ["Authorization": "Bearer token"]
                }
            }
        }

        let connecting = connecting(client)
        try await transport.accept().welcome()
        try await connecting.value

        XCTAssertEqual(
            transport.dialedWith.headers["Authorization"],
            "Bearer token",
            "expected the client to dial again after the header failed"
        )
    }

    func testAnUnsubscribeDuringAResubscribeGoesOutAfterIt() async throws {
        let transport = FakeTransport()
        transport.writeBuffer = 0
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)

        _ = try await subscribed(client, connection)
        let subscribing = subscribing(client, Identifier(channel: "OtherChannel"))
        try await connection.expectCommand(.subscribe, otherIdentifier)
        try await connection.confirm(otherIdentifier)
        let other = try await subscribing.value

        await connection.close()

        // The welcome sets the client resubscribing both. With nobody reading
        // yet it is stuck mid-list on the first write, which is when the
        // unsubscribe arrives and queues up behind it. Had it slipped in ahead
        // of the second subscribe, the server would have been left holding
        // OtherChannel with no one here to answer for it.
        let reconnected = try await transport.accept()
        try await reconnected.welcome()
        try await reconnected.beganWriting()
        let unsubscribing = Task { try await other.unsubscribe() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let first = try await reconnected.command()
        let second = try await reconnected.command()
        XCTAssertEqual(
            [first.command, second.command],
            [CommandName.subscribe.rawValue, CommandName.subscribe.rawValue],
            "expected both resubscribes before anything else"
        )
        XCTAssertEqual(Set([first.identifier, second.identifier]), Set([roomIdentifier, otherIdentifier]))
        try await reconnected.expectCommand(.unsubscribe, otherIdentifier)
        try await unsubscribing.value
    }

    func testAConnectThatRunsOutOfTimeStopsTheClient() async throws {
        let transport = FakeTransport()
        transport.failNextDial(TestError(what: "connection refused"))
        let client = newClient(transport) {
            $0.initialBackoff = 3600
            $0.longestBackoff = 3600
        }

        let connecting = connecting(client)
        try await Task.sleep(nanoseconds: 50_000_000)
        connecting.cancel()

        await assertThrows(try await connecting.value) { error in
            assertCable(error, .connectCancelled)
            XCTAssertEqual(
                (error as? ActionCableError)?.lastAttempt as? TestError,
                TestError(what: "connection refused"),
                "expected the error to say what the client was waiting out"
            )
        }

        let done = await stopped(client)
        XCTAssertTrue(done, "client kept running after connect gave up")

        assertCable(await client.error, .connectCancelled)
        await assertThrows(try await client.connect()) {
            assertCable($0, .connectCancelled, "expected a second connect to report the first one's failure")
        }
        try await transport.expectNoDial()
    }

    func testAConnectThatRunsOutOfTimeNamesTheHeaderThatFailed() async throws {
        let transport = FakeTransport()
        let noCredentials = TestError(what: "no credentials to hand over")
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.headerProvider = { throw noCredentials }
        }

        let connecting = connecting(client)
        try await Task.sleep(nanoseconds: 50_000_000)
        connecting.cancel()

        await assertThrows(try await connecting.value) { error in
            assertCable(error, .connectCancelled)
            XCTAssertEqual(
                (error as? ActionCableError)?.lastAttempt as? TestError,
                noCredentials,
                "expected the header error to be carried rather than hidden by the cancellation"
            )
        }
        try await transport.expectNoDial()
    }

    func testMaxAttemptsStopsTheClient() async throws {
        let transport = FakeTransport()
        let refused = TestError(what: "connection refused")
        transport.failNextDial(refused)
        transport.failNextDial(refused)
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.maxAttempts = 2
        }

        await assertThrows(try await client.connect()) { error in
            assertCable(error, .gaveUp)
            XCTAssertEqual(
                (error as? ActionCableError)?.lastAttempt as? TestError,
                refused,
                "expected the last attempt's error to be carried"
            )
        }

        let done = await stopped(client)
        XCTAssertTrue(done, "client kept running after its attempts ran out")
        assertCable(await client.error, .gaveUp)
        try await transport.expectNoDial()
    }

    func testAWelcomeResetsTheAttemptCount() async throws {
        let transport = FakeTransport()
        transport.failNextDial(TestError(what: "connection refused"))
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.maxAttempts = 3
        }
        let connection = try await welcomed(client, transport)

        // Losing the connection is the first failed attempt of the outage, and
        // the refused redial the second. Had the failure before the welcome
        // still counted, that would have been the third.
        transport.failNextDial(TestError(what: "connection refused"))
        await connection.close()

        try await transport.accept().welcome()
        let failure = await client.error
        XCTAssertNil(failure, "a failure before the welcome should not count against the outage after it")
    }

    func testGivingUpTellsSubscriptionsTheClientIsNotComingBack() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) {
            $0.reconnectImmediately()
            $0.maxAttempts = 1
        }
        let connection = try await welcomed(client, transport)

        let disconnections = Recorded<Bool>()
        let subscribing = subscribing(client, room(), onDisconnected: { disconnections.record($0) })
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        _ = try await subscribing.value

        // Losing the connection is the only attempt allowed, so the client is
        // done for, and the subscription should hear that rather than a promise
        // to return.
        await connection.close()

        let willReconnect = await disconnections.next()
        XCTAssertEqual(willReconnect, false, "onDisconnected promised a reconnect the client was about to give up on")

        let done = await stopped(client)
        XCTAssertTrue(done, "client kept running after its attempts ran out")
        assertCable(await client.error, .gaveUp)
        try await transport.expectNoDial()
    }

    func testDoneAndErrFollowTheClient() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }

        var failure = await client.error
        XCTAssertNil(failure, "a client that hasn't started has nothing to report")

        let connection = try await welcomed(client, transport)
        failure = await client.error
        XCTAssertNil(failure, "a running client has nothing to report")
        let alreadyDone = await stopped(client, within: 0.05)
        XCTAssertFalse(alreadyDone, "done reported a running client as stopped")

        try await connection.push(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)

        let done = await stopped(client)
        XCTAssertTrue(done, "done never came after the server hung up for good")

        let disconnected = await client.error as? DisconnectError
        XCTAssertEqual(disconnected?.reason, .unauthorized)
    }

    func testMessagesCloseAfterTheLastCallbackReturns() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let entered = Recorded<Bool>()
        let release = Signalled()
        let subscribing = subscribing(
            client,
            room(),
            onDisconnected: { _ in
                entered.record(true)
                await release.wait()
            }
        )
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        let subscription = try await subscribing.value
        let messages = MessageLog(subscription)

        await client.close()
        let inCallback = await entered.next()
        XCTAssertEqual(inCallback, true, "onDisconnected never ran")

        if case .ended = await messages.next(within: 0.1) {
            XCTFail("the message stream ended while a callback was still running")
        }

        release.signal()

        await expectStreamEnded(messages)
        assertCable(subscription.error, .closed)
    }

    func testUnsubscribedSubscriptionReportsWhy() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)

        XCTAssertNil(subscription.error, "a live subscription has nothing to report")

        try await subscription.unsubscribe()
        try await connection.expectCommand(.unsubscribe, roomIdentifier)

        assertCable(subscription.error, .unsubscribed)
    }

    func testRejectionAfterAReconnectReportsWhy() async throws {
        let transport = FakeTransport()
        let client = newClient(transport) { $0.reconnectImmediately() }
        let connection = try await welcomed(client, transport)
        let subscription = try await subscribed(client, connection)
        let messages = MessageLog(subscription)

        await connection.close()

        let reconnected = try await transport.accept()
        try await reconnected.welcome()
        try await reconnected.expectCommand(.subscribe, roomIdentifier)
        try await reconnected.push(
            #"{"type":"reject_subscription","identifier":"{\"channel\":\"RoomChannel\",\"id\":42}"}"#
        )

        await expectStreamEnded(messages)
        assertCable(subscription.error, .rejected)
    }

    func testUnsubscribeNeedsNoContext() async throws {
        let transport = FakeTransport()
        let client = newClient(transport)
        let connection = try await welcomed(client, transport)

        let subscribing = subscribing(client, room())
        try await connection.expectCommand(.subscribe, roomIdentifier)
        try await connection.confirm(roomIdentifier)
        let subscription = try await subscribing.value

        // The task the subscription was made under is long gone by the time the
        // caller is tearing down, and that must not stop the hang-up from going
        // out.
        subscribing.cancel()

        try await subscription.unsubscribe()
        try await connection.expectCommand(.unsubscribe, roomIdentifier)
    }
}

private struct Said: Decodable {
    let body: String
}

/// Counts what a callback was asked for, across the tasks it runs on.
final class Counter: @unchecked Sendable {
    private let mutex = NSLock()
    private var counted = 0

    @discardableResult
    func next() -> Int {
        mutex.lock()
        defer { mutex.unlock() }

        counted += 1

        return counted
    }

    var count: Int {
        mutex.lock()
        defer { mutex.unlock() }

        return counted
    }
}

/// A gate a test opens once, for holding a callback where it can be seen.
final class Signalled: @unchecked Sendable {
    private let mutex = NSLock()
    private var opened = false

    func signal() {
        mutex.lock()
        defer { mutex.unlock() }

        opened = true
    }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var isOpen: Bool {
        mutex.lock()
        defer { mutex.unlock() }

        return opened
    }
}
