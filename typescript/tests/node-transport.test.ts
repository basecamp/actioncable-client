import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  Client,
  CloseError,
  HandshakeError,
  MessageTooBigError,
  SUBPROTOCOL_V1_JSON,
  isStatusCloser,
  type Connection,
  type DialOptions,
} from "../src/index.js";
import { NodeTransport } from "../src/index.node.js";
import { OPCODE } from "../src/transport/rfc6455/frames.js";
import { LoopbackServer, WAIT } from "./loopback-server.js";
import { ROOM_IDENTIFIER, failure, receive, room, sleep, testLogger } from "./helpers.js";

let server: LoopbackServer;
const opened: Connection[] = [];

beforeEach(async () => {
  server = await LoopbackServer.start();
});

afterEach(async () => {
  await Promise.all(opened.splice(0).map((connection) => connection.close()));
  await server.stop();
});

async function dial(options: DialOptions = {}, transport = new NodeTransport()) {
  const connection = await transport.dial(server.url, options);
  opened.push(connection);

  return connection;
}

function read(connection: Connection): Promise<string> {
  return connection.read({ signal: AbortSignal.timeout(WAIT) });
}

describe("NodeTransport", () => {
  it("negotiates the subprotocol", async () => {
    const connection = await dial({ subprotocols: [SUBPROTOCOL_V1_JSON] });

    expect(connection.subprotocol).toBe(SUBPROTOCOL_V1_JSON);
    expect(
      (await server.accept()).header("Sec-WebSocket-Protocol"),
      "expected the client to offer the subprotocol",
    ).toBe(SUBPROTOCOL_V1_JSON);
  });

  it("sends the headers", async () => {
    await dial({
      subprotocols: [SUBPROTOCOL_V1_JSON],
      headers: new Headers({ Cookie: "session=secret", Origin: "https://example.com" }),
    });

    const peer = await server.accept();
    expect(peer.header("Cookie")).toBe("session=secret");
    expect(peer.header("Origin")).toBe("https://example.com");
    expect(peer.header("User-Agent")).toBe("actioncable-js");
    expect(peer.request.url).toBe("/cable");
  });

  it("sends the caller's user agent", async () => {
    await dial({ headers: new Headers({ "User-Agent": "custom-agent" }) });

    expect((await server.accept()).header("User-Agent")).toBe("custom-agent");
  });

  it("neutralizes header injection", async () => {
    // A `Headers` refuses a value with a CRLF in it outright, so this hands
    // the transport the pairs directly — the way a credential arriving from
    // somewhere else could.
    await dial({ headers: [["Authorization", "Bearer token\r\nX-Injected: gotcha"]] });

    const peer = await server.accept();
    expect(peer.header("X-Injected"), "expected the newlines to be neutralized").toBe("");
    expect(
      peer.header("Authorization").startsWith("Bearer token"),
      "expected the authorization header to survive",
    ).toBe(true);
  });

  it("round-trips messages", async () => {
    const connection = await dial({ subprotocols: [SUBPROTOCOL_V1_JSON] });
    const peer = await server.accept();

    await connection.write(`{"command":"subscribe"}`);
    expect(await peer.read()).toBe(`{"command":"subscribe"}`);

    peer.write(OPCODE.text, `{"type":"welcome"}`);
    expect(await read(connection)).toBe(`{"type":"welcome"}`);
  });

  it("answers pings", async () => {
    const connection = await dial();
    const peer = await server.accept();

    peer.write(OPCODE.ping, "beat");
    peer.write(OPCODE.text, "after the ping");

    expect(await read(connection)).toBe("after the ping");

    const frame = await peer.readFrame();
    expect(frame.opcode, "expected a pong").toBe(OPCODE.pong);
    expect(frame.payload.toString(), "expected the pong to carry the ping payload").toBe("beat");
  });

  it("reassembles fragments", async () => {
    const connection = await dial();
    const peer = await server.accept();

    peer.writeFragment(OPCODE.text, "one ", false);
    peer.writeFragment(OPCODE.ping, "interleaved", true);
    peer.writeFragment(OPCODE.continuation, "message", true);

    expect(await read(connection)).toBe("one message");
  });

  it("reads large messages", async () => {
    const connection = await dial();
    const peer = await server.accept();

    const long = "cable".repeat(30_000);
    peer.write(OPCODE.text, long);
    expect(await read(connection)).toBe(long);

    await connection.write(long);
    expect(await peer.read()).toBe(long);
  });

  it("refuses oversized messages", async () => {
    const connection = await dial({}, new NodeTransport({ maxMessageSize: 8 }));

    (await server.accept()).write(OPCODE.text, "far too long for eight bytes");

    await expect(read(connection)).rejects.toBeInstanceOf(MessageTooBigError);
  });

  it("refuses oversized fragmented messages", async () => {
    const connection = await dial({}, new NodeTransport({ maxMessageSize: 8 }));

    const peer = await server.accept();
    peer.writeFragment(OPCODE.text, "five ", false);
    peer.writeFragment(OPCODE.continuation, "more", true);

    await expect(read(connection)).rejects.toBeInstanceOf(MessageTooBigError);
  });

  it("reports a server close", async () => {
    const connection = await dial();

    const payload = Buffer.concat([codeOf(4401), Buffer.from("unauthorized")]);
    (await server.accept()).write(OPCODE.close, payload);

    const closed = await failure<CloseError>(read(connection));
    expect(closed, "expected a CloseError after the server closed").toBeInstanceOf(CloseError);
    expect(closed.code).toBe(4401);
    expect(closed.reason).toBe("unauthorized");
  });

  it("reports a server close without a status", async () => {
    const connection = await dial();

    (await server.accept()).write(OPCODE.close);

    const closed = await failure<CloseError>(read(connection));
    expect(closed, "expected a CloseError after the server closed").toBeInstanceOf(CloseError);
    expect(closed.code).toBe(1005);
    expect(closed.reason).toBe("");
  });

  it("closes with a status", async () => {
    const connection = await dial();
    const peer = await server.accept();

    expect(isStatusCloser(connection), "the built-in connection should be a StatusCloser").toBe(
      true,
    );
    if (!isStatusCloser(connection)) {
      return;
    }
    await connection.closeWithStatus(4000, "done here");

    const frame = await peer.readFrame();
    expect(frame.opcode).toBe(OPCODE.close);
    expect(frame.payload.readUInt16BE(0)).toBe(4000);
    expect(frame.payload.subarray(2).toString()).toBe("done here");
  });

  it("truncates a close reason to fit the frame", async () => {
    const connection = await dial();
    const peer = await server.accept();

    if (!isStatusCloser(connection)) {
      throw new Error("expected a StatusCloser");
    }
    await connection.closeWithStatus(4000, "r".repeat(200));

    const frame = await peer.readFrame();
    expect(frame.opcode).toBe(OPCODE.close);
    expect(frame.payload.length, "a control frame's payload is at most 125 bytes").toBe(125);
  });

  it("refuses a non-upgrade response", async () => {
    server.reception = "refuse";

    const refused = await failure<HandshakeError>(new NodeTransport().dial(server.url, {}));

    expect(
      refused,
      "expected a HandshakeError for a server that refuses to upgrade",
    ).toBeInstanceOf(HandshakeError);
    expect(refused.statusCode).toBe(404);
    expect(refused.status).toBe("404 Not Found");
  });

  it("does not follow a redirect", async () => {
    server.reception = "redirect";

    const refused = await failure<HandshakeError>(new NodeTransport().dial(server.url, {}));

    expect(refused, "expected a HandshakeError for a redirect").toBeInstanceOf(HandshakeError);
    expect(refused.statusCode).toBe(302);
  });

  it("refuses a bad accept key", async () => {
    server.reception = "bad-accept";

    await expect(
      new NodeTransport().dial(server.url, {}),
      "expected an error for a bad Sec-WebSocket-Accept",
    ).rejects.toThrow(/Sec-WebSocket-Accept/);
  });

  it("honors cancellation", async () => {
    const connection = await dial();
    await server.accept();

    await expect(
      connection.read({ signal: AbortSignal.timeout(50) }),
      "expected read to give up with the signal",
    ).rejects.toHaveProperty("name", "TimeoutError");
  });

  it("refuses a masked server frame", async () => {
    const connection = await dial();

    // RFC 6455 §5.1: a server must never mask, and a client that sees a masked
    // frame must fail the connection rather than quietly unmask it.
    (await server.accept()).writeMasked(OPCODE.text, `{"type":"welcome"}`);

    await expect(
      read(connection),
      "expected a masked frame to fail the connection",
    ).rejects.toThrow(/masked/);
  });

  it("replies to a close once", async () => {
    const connection = await dial();
    const peer = await server.accept();

    peer.write(OPCODE.close, codeOf(1000));
    await expect(read(connection), "expected an error after the server closed").rejects.toThrow();
    await connection.close();

    expect(await peer.closeFrames(), "expected exactly one close frame in reply").toBe(1);
  });

  it("runs the whole cable dance over a real socket", async () => {
    const client = new Client(server.url, { logger: testLogger() });

    const connecting = client.connect();
    const peer = await server.accept();
    peer.write(OPCODE.text, `{"type":"welcome"}`);
    await connecting;

    const subscribing = client.subscribe(room());
    expect(await peer.read()).toBe(
      `{"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}"}`,
    );
    peer.write(
      OPCODE.text,
      `{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}"}`,
    );

    const subscription = await subscribing;
    const messages = subscription.messages();

    peer.write(
      OPCODE.text,
      `{"identifier":${JSON.stringify(ROOM_IDENTIFIER)},"message":{"body":"Hello!"}}`,
    );
    expect((await receive(messages)).toString()).toBe(`{"body":"Hello!"}`);

    await subscription.perform("speak", { body: "Hi!" });
    expect(await peer.read()).toBe(
      `{"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}","data":"{\\"action\\":\\"speak\\",\\"body\\":\\"Hi!\\"}"}`,
    );

    await client.close();
    await sleep(10);
  });
});

function codeOf(code: number): Buffer {
  const payload = Buffer.allocUnsafe(2);
  payload.writeUInt16BE(code);

  return payload;
}
