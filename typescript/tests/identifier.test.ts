import { describe, expect, it } from "vitest";
import { identifierKey, type Identifier } from "../src/index.js";

describe("identifierKey", () => {
  it("keys an identifier", () => {
    const identifiers: Array<[Identifier, string]> = [
      [{ channel: "RoomChannel" }, `{"channel":"RoomChannel"}`],
      [{ channel: "RoomChannel", params: { id: 42 } }, `{"channel":"RoomChannel","id":42}`],
      [
        { channel: "RoomChannel", params: { id: 42, since: "yesterday" } },
        `{"channel":"RoomChannel","id":42,"since":"yesterday"}`,
      ],
      [
        { channel: "RoomChannel", params: { since: "yesterday", id: 42 } },
        `{"channel":"RoomChannel","id":42,"since":"yesterday"}`,
      ],
    ];

    for (const [identifier, key] of identifiers) {
      expect(identifierKey(identifier), identifier.channel).toBe(key);
    }
  });

  it("refuses params it cannot encode", () => {
    expect(() => identifierKey({ channel: "RoomChannel", params: { id: 1n } })).toThrow(TypeError);
  });
});
