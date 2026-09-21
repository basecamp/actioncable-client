import { describe, expect, it } from "vitest";
import {
  Client,
  ClosedError,
  DisconnectError,
  DisconnectReason,
  GaveUpError,
  Message,
  NoProtocolsError,
  NotConnectedError,
  RejectedError,
  SUBPROTOCOL_UNSUPPORTED,
  SUBPROTOCOL_V1_JSON,
  UnsubscribedError,
  UnsupportedSubprotocolError,
  V1JSON,
  type Command,
  type Incoming,
  type Protocol,
} from "../src/index.js";
import { FakeTransport } from "../src/testing/index.js";
import {
  OTHER_IDENTIFIER,
  ROOM_IDENTIFIER,
  expectCommand,
  expectEnded,
  failure,
  newTestClient,
  receive,
  room,
  sleep,
  stillPending,
  subscribed,
  testLogger,
  welcomed,
} from "./helpers.js";

/**
 * Speaks a made-up subprotocol and stamps everything it encodes, so a test can
 * tell which protocol the client settled on.
 */
class FakeProtocol implements Protocol {
  constructor(
    readonly subprotocol: string,
    readonly stamp: string,
  ) {}

  encode(command: Command): string {
    return this.stamp + new V1JSON().encode(command);
  }

  decode(payload: string): Incoming {
    return new V1JSON().decode(
      payload.startsWith(this.stamp) ? payload.slice(this.stamp.length) : payload,
    );
  }
}

const FAST_BACKOFF = { initial: 1, longest: 1 };

describe("Client", () => {
  it("connect waits for the welcome", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);

    const connecting = client.connect();
    const connection = await transport.accept();

    expect(await stillPending(connecting, 50), "connect returned before the welcome").toBe(true);

    await connection.welcome();
    await connecting;
    expect(client.connected, "client is not connected after the welcome").toBe(true);
  });

  it("connect retries until the server answers", async () => {
    const transport = new FakeTransport();
    transport.failNextDial(new Error("connection refused"));
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });

    const connecting = client.connect();
    await (await transport.accept()).welcome();

    await connecting;
  });

  it("subscribe receives messages", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const connections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onConnected: (reconnected) => void connections.push(reconnected),
    });

    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);

    const subscription = await subscribing;
    const messages = subscription.messages();

    await connection.broadcast(ROOM_IDENTIFIER, { body: "Hello!" });

    expect((await receive(messages)).json<{ body: string }>().body).toBe("Hello!");
    expect(connections, "first connection reported itself as a reconnect").toEqual([false]);
  });

  it("subscribe rejected", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    let rejections = 0;
    const subscribing = client.subscribe(room(), {
      onRejected: () => {
        rejections += 1;
      },
    });

    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.reject(ROOM_IDENTIFIER);

    await expect(subscribing).rejects.toBeInstanceOf(RejectedError);
    await sleep(20);
    expect(rejections, "onRejected was never called").toBe(1);
  });

  it("perform sends an action", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    await subscription.perform("speak", { body: "Hello!" });

    const command = await connection.command();
    expect(command.command).toBe("message");
    expect(command.identifier).toBe(ROOM_IDENTIFIER);
    expect(command.data, "expected the action alongside the data").toBe(
      `{"action":"speak","body":"Hello!"}`,
    );
  });

  it("send delivers data without an action", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    await subscription.send({ body: "Hello!" });

    const command = await connection.command();
    expect(command.data, "expected the data on its own").toBe(`{"body":"Hello!"}`);
  });

  it("send refuses data that cannot encode", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    await expect(subscription.send(() => {})).rejects.toBeInstanceOf(TypeError);
    await expect(subscription.send({ id: 1n })).rejects.toBeInstanceOf(TypeError);
  });

  it("perform refuses data that is not an object", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    await expect(subscription.perform("speak", ["nope"])).rejects.toBeInstanceOf(TypeError);
  });

  it("unsubscribe ends the messages and tells the server", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);
    const messages = subscription.messages();

    await subscription.unsubscribe();
    await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);

    await expectEnded(messages);
  });

  it("reconnect resubscribes", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    const connections: boolean[] = [];
    const disconnections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onConnected: (reconnected) => void connections.push(reconnected),
      onDisconnected: (willReconnect) => void disconnections.push(willReconnect),
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;

    await connection.close();

    const reconnected = await transport.accept();
    await reconnected.welcome();
    await expectCommand(reconnected, "subscribe", ROOM_IDENTIFIER);
    await reconnected.confirm(ROOM_IDENTIFIER);
    await sleep(20);

    expect(disconnections, "disconnect reported that the client would not reconnect").toEqual([
      true,
    ]);
    expect(
      connections,
      "expected the confirmation after a reconnect to report reconnected",
    ).toEqual([false, true]);
  });

  it("a stale connection is replaced", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { staleAfter: 75, backoff: FAST_BACKOFF });

    const connecting = client.connect();
    await (await transport.accept()).welcome();
    await connecting;

    // Say nothing at all: no pings, no messages. The connection goes stale.
    await (await transport.accept()).welcome();
  });

  it("an unconfirmed subscribe is retried", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { subscribeRetry: 20 });
    const connection = await welcomed(client, transport);

    const subscribing = client.subscribe(room());
    expect((await connection.dropCommand()).command).toBe("subscribe");
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);

    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;
  });

  it("a server disconnect without reconnect stops the client", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    await connection.disconnect(DisconnectReason.unauthorized, false);

    await transport.expectNoDial();
    expect(client.connected, "client is still connected after being told to go away").toBe(false);

    const refusal = await failure<DisconnectError>(client.subscribe(room()));
    expect(refusal).toBeInstanceOf(DisconnectError);
    expect(refusal.reason).toBe(DisconnectReason.unauthorized);
  });

  it("a server disconnect with reconnect dials again", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    await connection.disconnect(DisconnectReason.serverRestart, true);

    await (await transport.accept()).welcome();
  });

  it("the client offers every protocol and the sentinel", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, {
      protocols: [new V1JSON(), new FakeProtocol("actioncable-v2-json", "v2:")],
    });

    await welcomed(client, transport);

    expect(transport.offered).toEqual([
      SUBPROTOCOL_V1_JSON,
      "actioncable-v2-json",
      SUBPROTOCOL_UNSUPPORTED,
    ]);
  });

  it("additional protocols are offered first", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, {
      additionalProtocols: [new FakeProtocol("actioncable-v2-json", "v2:")],
    });

    await welcomed(client, transport);

    expect(transport.offered).toEqual([
      "actioncable-v2-json",
      SUBPROTOCOL_V1_JSON,
      SUBPROTOCOL_UNSUPPORTED,
    ]);
  });

  it("the client speaks the protocol the server picked", async () => {
    const transport = new FakeTransport();
    transport.subprotocol = "actioncable-v2-json";
    const client = newTestClient(transport, {
      protocols: [new V1JSON(), new FakeProtocol("actioncable-v2-json", "v2:")],
    });

    const connection = await welcomed(client, transport);
    // Nobody confirms it, so it is still waiting when the client is closed.
    const subscribing = client.subscribe(room()).catch(() => undefined);

    const sent = await connection.sent();
    expect(sent.startsWith("v2:"), `expected the negotiated protocol to encode ${sent}`).toBe(true);

    await client.close();
    await subscribing;
  });

  it("the unsupported sentinel stops the client", async () => {
    const transport = new FakeTransport();
    transport.subprotocol = SUBPROTOCOL_UNSUPPORTED;
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });

    await expect(client.connect()).rejects.toBeInstanceOf(UnsupportedSubprotocolError);

    await transport.accept();
    await transport.expectNoDial();
  });

  it("no protocols stops the client", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { protocols: [] });

    await expect(client.connect()).rejects.toBeInstanceOf(NoProtocolsError);

    await transport.expectNoDial();
  });

  it("an unsupported subprotocol stops the client", async () => {
    const transport = new FakeTransport();
    transport.subprotocol = "actioncable-v9-telepathy";
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });

    await expect(client.connect()).rejects.toBeInstanceOf(UnsupportedSubprotocolError);

    await transport.accept();
    await transport.expectNoDial();
  });

  it("subscribe before connect", async () => {
    const client = newTestClient(new FakeTransport());

    await expect(client.subscribe(room())).rejects.toBeInstanceOf(NotConnectedError);
  });

  it("close ends every subscription", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);
    const messages = subscription.messages();

    await client.close();

    await expectEnded(messages);
    await expect(subscription.perform("speak")).rejects.toBeInstanceOf(NotConnectedError);
  });

  it("messages arrive on every subscription sharing an identifier", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const first = await subscribed(client, connection);
    const second = await client.subscribe(room());

    await connection.broadcast(ROOM_IDENTIFIER, { body: "Hello!" });

    for (const subscription of [first, second]) {
      const message = await receive(subscription.messages());
      expect(message.toString(), "expected the broadcast").toBe(`{"body":"Hello!"}`);
    }

    // Only the last subscription standing tells the server to unsubscribe.
    await first.unsubscribe();
    await connection.expectNoCommand();

    await second.unsubscribe();
    await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);
  });

  it("subscribing to a confirmed identifier sends nothing", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    await subscribed(client, connection);

    // Rails has the identifier already and would ignore a second subscribe, so
    // the one confirmation it gave stands for this subscription too.
    const connections: boolean[] = [];
    await client.subscribe(room(), {
      onConnected: (reconnected) => void connections.push(reconnected),
    });
    await sleep(20);

    expect(
      connections,
      "a subscription joining a confirmed identifier reported itself as a reconnect",
    ).toEqual([false]);
    await connection.expectNoCommand();
  });

  it("subscribers join an in-flight subscribe", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const first = client.subscribe(room());
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    const second = client.subscribe(room());
    const third = client.subscribe(room());
    await connection.expectNoCommand();

    await connection.confirm(ROOM_IDENTIFIER);

    await Promise.all([first, second, third]);
  });

  it("subscribers joining an in-flight subscribe share its rejection", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const first = client.subscribe(room());
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    const second = client.subscribe(room());
    await connection.expectNoCommand();

    await connection.reject(ROOM_IDENTIFIER);

    await expect(first).rejects.toBeInstanceOf(RejectedError);
    await expect(second).rejects.toBeInstanceOf(RejectedError);
  });

  it("subscribers joining an in-flight subscribe follow it through a reconnect", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    const first = client.subscribe(room());
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    const second = client.subscribe(room());
    await connection.expectNoCommand();

    await connection.close();

    const reconnected = await transport.accept();
    await reconnected.welcome();
    await expectCommand(reconnected, "subscribe", ROOM_IDENTIFIER);
    await reconnected.expectNoCommand();
    await reconnected.confirm(ROOM_IDENTIFIER);

    await Promise.all([first, second]);
  });

  it("cancelling the only in-flight subscribe tells the server", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const giveUp = new AbortController();
    const subscribing = client.subscribe(room(), { signal: giveUp.signal });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);

    // The server has the subscription whether or not anyone here still wants
    // it, and would ignore the next subscribe for it unless told to let go.
    giveUp.abort();
    await expect(subscribing).rejects.toHaveProperty("name", "AbortError");
    await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);
    await connection.expectNoCommand();

    await subscribed(client, connection);
  });

  it("cancelling a subscriber joining an in-flight subscribe leaves the first waiting", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const first = client.subscribe(room());
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);

    const giveUp = new AbortController();
    const joining = client.subscribe(room(), { signal: giveUp.signal });
    await connection.expectNoCommand();

    giveUp.abort();
    await expect(joining).rejects.toHaveProperty("name", "AbortError");
    await connection.expectNoCommand();

    await connection.confirm(ROOM_IDENTIFIER);
    await first;
  });

  it("connect after close reports why it stopped", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    await welcomed(client, transport);

    await client.close();

    await expect(client.connect()).rejects.toBeInstanceOf(ClosedError);
    await transport.expectNoDial();
  });

  it("close before connect leaves the client dead", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);

    await client.close();

    await expect(client.connect()).rejects.toBeInstanceOf(ClosedError);
    expect(client.connected, "a client closed before it started reports itself connected").toBe(
      false,
    );
    await transport.expectNoDial();
  });

  it("close from onDisconnected", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    let closed: Promise<void> | null = null;
    const subscribing = client.subscribe(room(), {
      onDisconnected: () => {
        closed = client.close();
      },
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;

    await connection.close();
    await sleep(50);

    expect(closed, "onDisconnected never ran").not.toBeNull();
    await closed;
  });

  it("subscribe from onConnected", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    let joined: Promise<unknown> | null = null;
    const subscribing = client.subscribe(room(), {
      onConnected: () => {
        joined = client.subscribe({ channel: "OtherChannel" });
      },
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;

    await expectCommand(connection, "subscribe", OTHER_IDENTIFIER);
    await connection.confirm(OTHER_IDENTIFIER);
    await joined;
  });

  it("unsubscribe while messages arrive", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { messageBuffer: 1 });
    const connection = await welcomed(client, transport);

    for (let round = 0; round < 50; round += 1) {
      const subscription = await subscribed(client, connection);

      const pushed = connection.broadcast(ROOM_IDENTIFIER, { body: "Hello!" });

      await subscription.unsubscribe();
      await pushed;
      await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);
    }
  });

  it("the first connection is not a reconnect", async () => {
    const transport = new FakeTransport();
    transport.failNextDial(new Error("connection refused"));
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });

    const connecting = client.connect();
    const connection = await transport.accept();
    await connection.welcome();
    await connecting;

    const connections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onConnected: (reconnected) => void connections.push(reconnected),
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;
    await sleep(20);

    expect(
      connections,
      "a first connection that took two dials reported itself as a reconnect",
    ).toEqual([false]);
  });

  it("perform before the welcome is refused", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    await connection.close();
    await transport.accept();

    // The connection is up again but not yet welcomed, and the server throws
    // away anything sent that early, so a command then is not a command landed.
    await expect(subscription.perform("speak")).rejects.toBeInstanceOf(NotConnectedError);
  });

  it("a repeated confirmation connects once", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const connections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onConnected: (reconnected) => void connections.push(reconnected),
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;

    await connection.confirm(ROOM_IDENTIFIER);
    await sleep(100);

    expect(connections, "a second confirmation reported a second connection").toEqual([false]);
  });

  it("the origin defaults to the cable URL", async () => {
    const origins = {
      "wss://cable.example.com/cable": "https://cable.example.com",
      "ws://cable.example.com:3000/cable": "http://cable.example.com:3000",
      "wss://cable.example.com:8443/cable": "https://cable.example.com:8443",
    };

    // Rails compares Origin against the host it serves on, and turns down a
    // request that carries no Origin at all.
    for (const [url, origin] of Object.entries(origins)) {
      const transport = new FakeTransport();
      const client = new Client(url, { transport, logger: testLogger() });

      const connecting = client.connect();
      await (await transport.accept()).welcome();
      await connecting;

      expect(transport.header("Origin"), url).toBe(origin);
      await client.close();
    }
  });

  it("an explicit origin wins", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { origin: "https://app.example.com" });

    const connecting = client.connect();
    await (await transport.accept()).welcome();
    await connecting;

    expect(transport.header("Origin"), "expected the origin given").toBe("https://app.example.com");
  });

  it("the headers are copied", async () => {
    const transport = new FakeTransport();
    const headers = new Headers({ Cookie: "session=secret" });
    const client = newTestClient(transport, { headers });

    headers.set("Cookie", "session=tampered");

    const connecting = client.connect();
    await (await transport.accept()).welcome();
    await connecting;

    expect(transport.header("Cookie"), "expected the headers as they were given").toBe(
      "session=secret",
    );
  });

  it("every dial asks for the headers again", async () => {
    const transport = new FakeTransport();
    transport.failNextDial(new Error("connection refused"));

    let dials = 0;
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      headers: { Origin: "https://app.example.com" },
      headersFor: () => {
        dials += 1;
        return { Authorization: `Bearer token-${dials}` };
      },
    });

    const connecting = client.connect();
    await (await transport.accept()).welcome();
    await connecting;

    expect(
      transport.header("Authorization"),
      "expected the redial to carry the credentials it asked for then",
    ).toBe("Bearer token-2");
    expect(transport.header("Origin"), "expected the headers set once to survive").toBe(
      "https://app.example.com",
    );
  });

  it("a terminal dial error stops the initial connection", async () => {
    const transport = new FakeTransport();
    const denied = new Error("connection denied");
    transport.failNextDial(denied);
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      stopOnError: (error) => error === denied,
    });

    await expect(client.connect()).rejects.toBe(denied);
    expect(client.error).toBe(denied);
    await transport.expectNoDial();
  });

  it("a non-terminal connection error still reconnects", async () => {
    const transport = new FakeTransport();
    const signedOut = new Error("sign in again");
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      stopOnError: (error) => error === signedOut,
    });
    const connection = await welcomed(client, transport);

    await connection.close();
    await (await transport.accept()).welcome();

    expect(client.error, "a retryable error stopped the client").toBeNull();
  });

  it("a terminal connection error stops the subscriptions", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      stopOnError: (error) => error instanceof Error && error.message.includes("closed"),
    });
    const connection = await welcomed(client, transport);

    const disconnections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onDisconnected: (willReconnect) => void disconnections.push(willReconnect),
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    const subscription = await subscribing;
    const messages = subscription.messages();

    await connection.close();
    await client.done;
    await sleep(20);

    expect(disconnections, "onDisconnected promised a reconnect after a terminal error").toEqual([
      false,
    ]);
    await expectEnded(messages);
    expect(subscription.error?.message).toContain("closed");
    await transport.expectNoDial();
  });

  it("a terminal header error stops the initial connection", async () => {
    const transport = new FakeTransport();
    const signedOut = new Error("sign in again");
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      stopOnError: (error) => error === signedOut,
      headersFor: () => {
        throw signedOut;
      },
    });

    await expect(client.connect()).rejects.toBe(signedOut);
    expect(client.error).toBe(signedOut);
    await transport.expectNoDial();
  });

  it("a terminal header error stops a reconnect", async () => {
    const transport = new FakeTransport();
    const signedOut = new Error("sign in again");
    let asked = 0;
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      stopOnError: (error) => error === signedOut,
      headersFor: () => {
        asked += 1;
        if (asked === 1) {
          return { Authorization: "Bearer token" };
        }
        throw signedOut;
      },
    });

    const connection = await welcomed(client, transport);
    await connection.close();

    await client.done;
    expect(client.error).toBe(signedOut);
    expect(asked, "expected one initial header and one failed reconnect header").toBe(2);
    await transport.expectNoDial();
  });

  it("a dial is turned down when the headers cannot be built", async () => {
    const transport = new FakeTransport();

    let asked = 0;
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      headersFor: () => {
        asked += 1;
        if (asked === 1) {
          throw new Error("no credentials to hand over");
        }
        return { Authorization: "Bearer token" };
      },
    });

    const connecting = client.connect();
    await (await transport.accept()).welcome();
    await connecting;

    expect(
      transport.header("Authorization"),
      "expected the client to dial again after the headers failed",
    ).toBe("Bearer token");
  });

  it("an unsubscribe during a resubscribe goes out after it", async () => {
    const transport = new FakeTransport();
    transport.writeBuffer = 0;
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);

    await subscribed(client, connection);
    const subscribing = client.subscribe({ channel: "OtherChannel" });
    await expectCommand(connection, "subscribe", OTHER_IDENTIFIER);
    await connection.confirm(OTHER_IDENTIFIER);
    const other = await subscribing;

    await connection.close();

    // The welcome sets the client resubscribing both. With nobody reading yet
    // it is stuck mid-list on the first write, which is when the unsubscribe
    // arrives and queues up behind it. Had it slipped in ahead of the second
    // subscribe, the server would have been left holding OtherChannel with no
    // one here to answer for it.
    const reconnected = await transport.accept();
    await reconnected.welcome();
    await reconnected.writing;
    const unsubscribing = other.unsubscribe();
    await sleep(20);

    const first = await reconnected.command();
    const second = await reconnected.command();
    expect(
      [first.command, second.command],
      "expected both resubscribes before anything else",
    ).toEqual(["subscribe", "subscribe"]);
    expect([first.identifier, second.identifier].sort()).toEqual(
      [ROOM_IDENTIFIER, OTHER_IDENTIFIER].sort(),
    );
    await expectCommand(reconnected, "unsubscribe", OTHER_IDENTIFIER);
    await unsubscribing;
  });

  it("a connect that runs out of time stops the client", async () => {
    const transport = new FakeTransport();
    transport.failNextDial(new Error("connection refused"));
    const client = newTestClient(transport, {
      backoff: { initial: 3_600_000, longest: 3_600_000 },
    });

    const timedOut = await failure(client.connect({ signal: AbortSignal.timeout(50) }));

    expect(timedOut.name).toBe("TimeoutError");
    expect(timedOut.message, "expected the error to say what the client was waiting out").toContain(
      "connection refused",
    );

    await client.done;
    expect(client.error?.name).toBe("TimeoutError");
    await expect(
      client.connect(),
      "expected a second connect to report the first one's failure",
    ).rejects.toHaveProperty("name", "TimeoutError");
    await transport.expectNoDial();
  });

  it("a connect that runs out of time names the headers that failed", async () => {
    const transport = new FakeTransport();
    const noCredentials = new Error("no credentials to hand over");
    const client = newTestClient(transport, {
      backoff: FAST_BACKOFF,
      headersFor: () => {
        throw noCredentials;
      },
    });

    const timedOut = await failure(client.connect({ signal: AbortSignal.timeout(50) }));

    expect(timedOut.name).toBe("TimeoutError");
    expect(
      timedOut.message,
      "expected the header error to be named rather than hidden by the deadline",
    ).toContain("no credentials to hand over");
    await transport.expectNoDial();
  });

  it("max attempts stops the client", async () => {
    const transport = new FakeTransport();
    const refused = new Error("connection refused");
    transport.failNextDial(refused);
    transport.failNextDial(refused);
    const client = newTestClient(transport, { backoff: FAST_BACKOFF, maxAttempts: 2 });

    const gaveUp = await failure<GaveUpError>(client.connect());

    expect(gaveUp).toBeInstanceOf(GaveUpError);
    expect(gaveUp.cause, "expected the last attempt's error to be carried").toBe(refused);

    await client.done;
    expect(client.error).toBeInstanceOf(GaveUpError);
    await transport.expectNoDial();
  });

  it("a welcome resets the attempt count", async () => {
    const transport = new FakeTransport();
    transport.failNextDial(new Error("connection refused"));
    const client = newTestClient(transport, { backoff: FAST_BACKOFF, maxAttempts: 3 });
    const connection = await welcomed(client, transport);

    // Losing the connection is the first failed attempt of the outage, and the
    // refused redial the second. Had the failure before the welcome still
    // counted, that would have been the third.
    transport.failNextDial(new Error("connection refused"));
    await connection.close();

    await (await transport.accept()).welcome();
    expect(
      client.error,
      "a failure before the welcome should not count against the outage after it",
    ).toBeNull();
  });

  it("giving up tells the subscriptions the client is not coming back", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF, maxAttempts: 1 });
    const connection = await welcomed(client, transport);

    const disconnections: boolean[] = [];
    const subscribing = client.subscribe(room(), {
      onDisconnected: (willReconnect) => void disconnections.push(willReconnect),
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    await subscribing;

    // Losing the connection is the only attempt allowed, so the client is done
    // for, and the subscription should hear that rather than a promise to
    // return.
    await connection.close();
    await client.done;
    await sleep(20);

    expect(
      disconnections,
      "onDisconnected promised a reconnect the client was about to give up on",
    ).toEqual([false]);
    expect(client.error).toBeInstanceOf(GaveUpError);
    await transport.expectNoDial();
  });

  it("done and error follow the client", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });

    expect(client.error, "a client that hasn't started has nothing to report").toBeNull();
    const connection = await welcomed(client, transport);
    expect(client.error, "a running client has nothing to report").toBeNull();
    expect(await stillPending(client.done, 20), "done settled on a running client").toBe(true);

    await connection.disconnect(DisconnectReason.unauthorized, false);

    await client.done;

    expect(client.error).toBeInstanceOf(DisconnectError);
    expect((client.error as DisconnectError).reason).toBe(DisconnectReason.unauthorized);
  });

  it("messages end after the last callback returns", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    let entered!: () => void;
    const inCallback = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });

    const subscribing = client.subscribe(room(), {
      onDisconnected: async () => {
        entered();
        await held;
      },
    });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    const subscription = await subscribing;
    const messages = subscription.messages();

    await client.close();
    await inCallback;

    const ending = messages.next();
    expect(
      await stillPending(ending, 100),
      "the messages ended while a callback was still running",
    ).toBe(true);

    release();

    expect((await ending).done, "messages are still being delivered").toBe(true);
    expect(subscription.error).toBeInstanceOf(ClosedError);
  });

  it("an unsubscribed subscription reports why", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);

    expect(subscription.error, "a live subscription has nothing to report").toBeNull();

    await subscription.unsubscribe();
    await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);

    expect(subscription.error).toBeInstanceOf(UnsubscribedError);
  });

  it("a rejection after a reconnect reports why", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport, { backoff: FAST_BACKOFF });
    const connection = await welcomed(client, transport);
    const subscription = await subscribed(client, connection);
    const messages = subscription.messages();

    await connection.close();

    const reconnected = await transport.accept();
    await reconnected.welcome();
    await expectCommand(reconnected, "subscribe", ROOM_IDENTIFIER);
    await reconnected.reject(ROOM_IDENTIFIER);

    await expectEnded(messages);
    expect(subscription.error).toBeInstanceOf(RejectedError);
  });

  it("unsubscribe needs no signal", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const giveUp = new AbortController();
    const subscribing = client.subscribe(room(), { signal: giveUp.signal });
    await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
    await connection.confirm(ROOM_IDENTIFIER);
    const subscription = await subscribing;

    // The signal the subscription was made under is long gone by the time the
    // caller is tearing down, and that must not stop the hang-up going out.
    giveUp.abort();

    await subscription.unsubscribe();
    await expectCommand(connection, "unsubscribe", ROOM_IDENTIFIER);
  });

  it("onMessage is the event-shaped way to read a subscription", async () => {
    const transport = new FakeTransport();
    const client = newTestClient(transport);
    const connection = await welcomed(client, transport);

    const said: string[] = [];
    const subscription = await subscribed(client, connection, {
      onMessage: (message: Message) => void said.push(message.toString()),
    });

    await connection.broadcast(ROOM_IDENTIFIER, { body: "Hello!" });
    await sleep(20);

    expect(said).toEqual([`{"body":"Hello!"}`]);
    expect(() => subscription.messages()).toThrow(TypeError);
  });
});
