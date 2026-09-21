import { expect, onTestFinished } from "vitest";
import { Client } from "../src/index.js";
import type { ClientOptions, Identifier, Logger, Message, SubscribeOptions } from "../src/index.js";
import type { Subscription } from "../src/index.js";
import type { FakeConnection, FakeTransport } from "../src/testing/index.js";

/** How long a test will hang around for something that should already have happened. */
export const WAIT = 2_000;

export const ROOM_IDENTIFIER = `{"channel":"RoomChannel","id":42}`;
export const OTHER_IDENTIFIER = `{"channel":"OtherChannel"}`;

export function room(): Identifier {
  return { channel: "RoomChannel", params: { id: 42 } };
}

export function newTestClient(transport: FakeTransport, options: ClientOptions = {}): Client {
  const client = new Client("ws://cable.example.com/cable", {
    transport,
    logger: testLogger(),
    ...options,
  });
  onTestFinished(() => client.close());

  return client;
}

/**
 * Connects a client and plays the server's welcome, answering with the
 * connection the test can go on talking over.
 */
export async function welcomed(client: Client, transport: FakeTransport): Promise<FakeConnection> {
  const connecting = client.connect();
  const connection = await transport.accept();
  await connection.welcome();
  await connecting;

  return connection;
}

export async function subscribed(
  client: Client,
  connection: FakeConnection,
  options: SubscribeOptions = {},
): Promise<Subscription> {
  const subscribing = client.subscribe(room(), options);
  await expectCommand(connection, "subscribe", ROOM_IDENTIFIER);
  await connection.confirm(ROOM_IDENTIFIER);

  return await subscribing;
}

export async function expectCommand(
  connection: FakeConnection,
  name: string,
  identifier: string,
): Promise<void> {
  const command = await connection.command();

  expect(command.command).toBe(name);
  expect(command.identifier).toBe(identifier);
}

/** Reads one message, and fails rather than hanging when none arrives. */
export async function receive(messages: AsyncIterator<Message>): Promise<Message> {
  const result = await within(messages.next(), WAIT, "no message arrived");

  expect(result.done, "messages ended").not.toBe(true);

  return result.value;
}

/** Asserts the subscription's messages have ended. */
export async function expectEnded(messages: AsyncIterator<Message>): Promise<void> {
  const result = await within(messages.next(), WAIT, "messages never ended");

  expect(result.done, "messages are still being delivered").toBe(true);
}

/** What a promise rejected with, and a failure of its own when it didn't. */
export async function failure<T = Error>(promise: Promise<unknown>): Promise<T> {
  try {
    await promise;
  } catch (error) {
    return error as T;
  }

  throw new Error("expected the promise to reject");
}

/** Whether a promise is still unsettled after the time given. */
export async function stillPending(promise: Promise<unknown>, within = 100): Promise<boolean> {
  const waiting = Symbol("waiting");
  const outcome = await Promise.race([
    promise.then(
      () => null,
      () => null,
    ),
    sleep(within).then(() => waiting),
  ]);

  return outcome === waiting;
}

/** Fails with `complaint` rather than hanging when the promise takes too long. */
export function within<T>(
  promise: Promise<T>,
  milliseconds: number,
  complaint: string,
): Promise<T> {
  return Promise.race([
    promise,
    sleep(milliseconds).then<T>(() => {
      throw new Error(complaint);
    }),
  ]);
}

export function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

/**
 * Sends the client's chatter nowhere by default. Set `ACTIONCABLE_TEST_LOG` to
 * see it while chasing a failure.
 */
export function testLogger(): Logger {
  if (process.env.ACTIONCABLE_TEST_LOG === undefined) {
    return { log() {} };
  } else {
    return { log: (message) => console.log(message) };
  }
}
