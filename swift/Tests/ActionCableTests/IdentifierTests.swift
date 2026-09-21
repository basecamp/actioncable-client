import ActionCable
import XCTest

final class IdentifierTests: XCTestCase {
    func testIdentifierKey() throws {
        let identifiers: [(Identifier, String)] = [
            (Identifier(channel: "RoomChannel"), #"{"channel":"RoomChannel"}"#),
            (Identifier(channel: "RoomChannel", params: ["id": 42]), #"{"channel":"RoomChannel","id":42}"#),
            (
                Identifier(channel: "RoomChannel", params: ["id": 42, "since": "yesterday"]),
                #"{"channel":"RoomChannel","id":42,"since":"yesterday"}"#
            ),
        ]

        for (identifier, key) in identifiers {
            XCTAssertEqual(try identifier.key(), key)
            XCTAssertEqual(identifier.description, key, "description should be the key")
        }
    }

    func testIdentifierKeyRefusesParamsItCannotEncode() {
        let identifier = Identifier(channel: "RoomChannel", params: ["id": .double(.nan)])

        XCTAssertThrowsError(try identifier.key(), "expected an error for params that don't encode")
    }
}
