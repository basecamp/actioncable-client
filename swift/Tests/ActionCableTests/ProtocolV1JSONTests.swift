import ActionCable
import Foundation
import XCTest

final class ProtocolV1JSONTests: XCTestCase {
    func testV1JSONSubprotocol() {
        XCTAssertEqual(V1JSON().subprotocol, "actioncable-v1-json")
    }

    func testV1JSONEncode() throws {
        let commands: [(Command, String)] = [
            (
                Command(name: .subscribe, identifier: #"{"channel":"RoomChannel"}"#),
                #"{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\"}"}"#
            ),
            (
                Command(name: .unsubscribe, identifier: #"{"channel":"RoomChannel"}"#),
                #"{"command":"unsubscribe","identifier":"{\"channel\":\"RoomChannel\"}"}"#
            ),
            (
                Command(name: .message, identifier: #"{"channel":"RoomChannel"}"#, data: #"{"action":"speak"}"#),
                #"{"command":"message","identifier":"{\"channel\":\"RoomChannel\"}","data":"{\"action\":\"speak\"}"}"#
            ),
        ]

        for (command, encoded) in commands {
            XCTAssertEqual(String(decoding: try V1JSON().encode(command), as: UTF8.self), encoded)
        }
    }

    func testV1JSONDecode() throws {
        let frames: [(String, Incoming)] = [
            (#"{"type":"welcome"}"#, Incoming(kind: .welcome)),
            (
                #"{"type":"ping","message":1755400000}"#,
                Incoming(kind: .ping, message: Message(Data("1755400000".utf8)))
            ),
            (
                #"{"type":"disconnect","reason":"server_restart","reconnect":true}"#,
                Incoming(kind: .disconnect, reason: .serverRestart, reconnect: true)
            ),
            (
                #"{"type":"confirm_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
                Incoming(kind: .confirmation, identifier: #"{"channel":"RoomChannel"}"#)
            ),
            (
                #"{"type":"reject_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}"#,
                Incoming(kind: .rejection, identifier: #"{"channel":"RoomChannel"}"#)
            ),
            (
                #"{"identifier":"{\"channel\":\"RoomChannel\"}","message":{"body":"Hello!"}}"#,
                Incoming(
                    kind: .message,
                    identifier: #"{"channel":"RoomChannel"}"#,
                    message: Message(Data(#"{"body":"Hello!"}"#.utf8))
                )
            ),
            (
                #"{"type":"something_new","identifier":"x","message":"anything"}"#,
                Incoming(kind: .message, identifier: "x", message: Message(Data(#""anything""#.utf8)))
            ),
        ]

        for (payload, expected) in frames {
            let incoming = try V1JSON().decode(Data(payload.utf8))

            XCTAssertEqual(incoming.kind, expected.kind, payload)
            XCTAssertEqual(incoming.identifier, expected.identifier, payload)
            XCTAssertEqual(incoming.message?.text, expected.message?.text, payload)
            XCTAssertEqual(incoming.reason, expected.reason, payload)
            XCTAssertEqual(incoming.reconnect, expected.reconnect, payload)
        }
    }

    func testV1JSONDecodeGarbage() {
        XCTAssertThrowsError(try V1JSON().decode(Data("not json".utf8)), "expected an error decoding garbage")
    }
}
