import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  Client,
  CloseError,
  HandshakeError,
  SUBPROTOCOL_V1_JSON,
  WebSocketTransport,
  isStatusCloser,
  type Connection,
} from "../src/index.js";
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

async function dial(subprotocols: string[] = []): Promise<Connection> {
  const connection = await new WebSocketTransport().dial(server.url, { subprotocols });
  opened.push(connection);

  return connection;
}

describe("WebSocketTransport", () => {
  it("negotiates the subprotocol", async () => {
    const connection = await dial([SUBPROTOCOL_V1_JSON]);

    expect(connection.subprotocol).toBe(SUBPROTOCOL_V1_JSON);
    expect((await server.accept()).header("Sec-WebSocket-Protocol")).toContain(SUBPROTOCOL_V1_JSON);
  });

  it("round-trips messages", async () => {
    const connection = await dial([SUBPROTOCOL_V1_JSON]);
    const peer = await server.accept();

    await connection.write(`{"command":"subscribe"}`);
    expect(await peer.read()).toBe(`{"command":"subscribe"}`);

    peer.write(OPCODE.text, `{"type":"welcome"}`);
    expect(await connection.read({ signal: AbortSignal.timeout(WAIT) })).toBe(`{"type":"welcome"}`);
  });

  it("reports a server close", async () => {
    const connection = await dial();

    const payload = Buffer.concat([codeOf(4401), Buffer.from("unauthorized")]);
    const peer = await server.accept();
    peer.write(OPCODE.close, payload);
    // The platform's WebSocket reports the close once the socket goes, not on
    // the frame alone, which is the server's job to finish either way.
    peer.end();

    const closed = await failure<CloseError>(
      connection.read({ signal: AbortSignal.timeout(WAIT) }),
    );

    expect(closed).toBeInstanceOf(CloseError);
    expect(closed.code).toBe(4401);
    expect(closed.reason).toBe("unauthorized");
  });

  it("closes with a status", async () => {
    const connection = await dial();
    const peer = await server.accept();

    expect(isStatusCloser(connection)).toBe(true);
    if (!isStatusCloser(connection)) {
      return;
    }
    await connection.closeWithStatus(4000, "done here");

    const frame = await peer.readFrame();
    expect(frame.opcode).toBe(OPCODE.close);
    expect(frame.payload.readUInt16BE(0)).toBe(4000);
    expect(frame.payload.subarray(2).toString()).toBe("done here");
  });

  it("refuses a non-upgrade response", async () => {
    server.reception = "refuse";

    await expect(new WebSocketTransport().dial(server.url, {})).rejects.toBeInstanceOf(
      HandshakeError,
    );
  });

  it("sends no headers of its own, because a page cannot", async () => {
    await dial();

    // The platform decides what an opening WebSocket request carries. This
    // records what the runtime sends so the README's claim stays true.
    expect((await server.accept()).header("Cookie")).toBe("");
  });

  it("runs the whole cable dance over a real socket", async () => {
    const client = new Client(server.url, {
      transport: new WebSocketTransport(),
      logger: testLogger(),
    });

    const connecting = client.connect();
    const peer = await server.accept();
    peer.write(OPCODE.text, `{"type":"welcome"}`);
    await connecting;

    const subscribing = client.subscribe(room());
    expect(await peer.read()).toBe(
      `{"command":"subscribe","identifier":${JSON.stringify(ROOM_IDENTIFIER)}}`,
    );
    peer.write(
      OPCODE.text,
      `{"type":"confirm_subscription","identifier":${JSON.stringify(ROOM_IDENTIFIER)}}`,
    );

    const subscription = await subscribing;
    const messages = subscription.messages();

    peer.write(
      OPCODE.text,
      `{"identifier":${JSON.stringify(ROOM_IDENTIFIER)},"message":{"body":"Hello!"}}`,
    );
    expect((await receive(messages)).toString()).toBe(`{"body":"Hello!"}`);

    await client.close();
    await sleep(10);
  });
});

function codeOf(code: number): Buffer {
  const payload = Buffer.allocUnsafe(2);
  payload.writeUInt16BE(code);

  return payload;
}
