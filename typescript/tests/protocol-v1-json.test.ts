import { describe, expect, it } from "vitest";
import { DisconnectReason, V1JSON, type Command, type IncomingKind } from "../src/index.js";

/** An expected frame, with the message as the text it decodes to. */
interface Decoded {
  kind: IncomingKind;
  identifier?: string;
  message?: string;
  reason?: string;
  reconnect?: boolean;
}

describe("V1JSON", () => {
  it("names its subprotocol", () => {
    expect(new V1JSON().subprotocol).toBe("actioncable-v1-json");
  });

  it("encodes", () => {
    const commands: Array<[Command, string]> = [
      [
        { name: "subscribe", identifier: `{"channel":"RoomChannel"}` },
        `{"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}`,
      ],
      [
        { name: "unsubscribe", identifier: `{"channel":"RoomChannel"}` },
        `{"command":"unsubscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}`,
      ],
      [
        {
          name: "message",
          identifier: `{"channel":"RoomChannel"}`,
          data: `{"action":"speak"}`,
        },
        `{"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\"}","data":"{\\"action\\":\\"speak\\"}"}`,
      ],
    ];

    for (const [command, encoded] of commands) {
      expect(new V1JSON().encode(command), command.name).toBe(encoded);
    }
  });

  it("decodes", () => {
    const frames: Array<[string, Decoded]> = [
      [`{"type":"welcome"}`, { kind: "welcome" }],
      [`{"type":"ping","message":1755400000}`, { kind: "ping", message: "1755400000" }],
      [
        `{"type":"disconnect","reason":"server_restart","reconnect":true}`,
        { kind: "disconnect", reason: DisconnectReason.serverRestart, reconnect: true },
      ],
      [
        `{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}`,
        { kind: "confirmation", identifier: `{"channel":"RoomChannel"}` },
      ],
      [
        `{"type":"reject_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}`,
        { kind: "rejection", identifier: `{"channel":"RoomChannel"}` },
      ],
      [
        `{"identifier":"{\\"channel\\":\\"RoomChannel\\"}","message":{"body":"Hello!"}}`,
        {
          kind: "message",
          identifier: `{"channel":"RoomChannel"}`,
          message: `{"body":"Hello!"}`,
        },
      ],
      [
        `{"type":"something_new","identifier":"x","message":"anything"}`,
        { kind: "message", identifier: "x", message: `"anything"` },
      ],
    ];

    for (const [payload, expected] of frames) {
      const incoming = new V1JSON().decode(payload);

      expect(incoming.kind, payload).toBe(expected.kind);
      expect(incoming.identifier, payload).toBe(expected.identifier ?? "");
      expect(incoming.message.toString(), payload).toBe(expected.message ?? "");
      expect(incoming.reason, payload).toBe(expected.reason ?? "");
      expect(incoming.reconnect, payload).toBe(expected.reconnect ?? false);
    }
  });

  it("refuses garbage", () => {
    expect(() => new V1JSON().decode("not json")).toThrow(SyntaxError);
    expect(() => new V1JSON().decode(`["not an object"]`)).toThrow(SyntaxError);
  });
});
