import { RejectedError, UnsubscribedError } from "./errors.js";
import { Dispatcher } from "./internal/dispatcher.js";
import { Deferred } from "./internal/deferred.js";
import { MessageBuffer } from "./internal/message-buffer.js";
import type { Logger } from "./logger.js";
import { Message } from "./message.js";
import type { SendOptions, SubscribeOptions } from "./options.js";

/**
 * What a subscription needs of the client that owns it. The client implements
 * it; naming it here keeps the two files from importing each other.
 */
export interface SubscriptionHost {
  sendMessage(identifier: string, data: string, options?: SendOptions): Promise<void>;
  forget(subscription: Subscription, reason: Error): { last: boolean; heard: boolean };
  sendUnsubscribe(identifier: string): Promise<void>;
}

/**
 * One channel subscription on a client. Read what the channel sends by
 * iterating it or with an `onMessage` callback, and talk back with `perform`
 * or `send`.
 *
 * ```ts
 * for await (const message of room) {
 *   console.log(message.json<{ body: string }>().body);
 * }
 * ```
 *
 * The iteration ends when the subscription is unsubscribed, rejected, or the
 * client stops, once the last callback has returned — `error` says which it
 * was. Read it promptly: messages that arrive with the buffer full are dropped
 * and logged rather than stalling the connection.
 */
export class Subscription implements AsyncIterable<Message> {
  readonly #host: SubscriptionHost;
  readonly #identifier: string;
  readonly #messages: MessageBuffer;
  readonly #callbacks: Dispatcher;
  readonly #options: SubscribeOptions;

  readonly #confirmed = new Deferred();
  readonly #rejected = new Deferred();

  #closed = false;
  #error: Error | null = null;

  constructor(
    host: SubscriptionHost,
    identifier: string,
    buffer: number,
    options: SubscribeOptions,
    logger: Logger,
  ) {
    this.#host = host;
    this.#identifier = identifier;
    this.#messages = new MessageBuffer(buffer);
    this.#options = options;
    this.#callbacks = new Dispatcher(() => this.#messages.end(), logger);

    if (options.onMessage !== undefined) {
      void this.#deliverToCallback(options.onMessage);
    }
  }

  /**
   * The JSON identifier string the server knows this subscription by, and the
   * one it echoes back on everything it sends here.
   */
  get key(): string {
    return this.#identifier;
  }

  /**
   * Why the subscription ended: an `UnsubscribedError`, a `RejectedError`, or
   * whatever stopped the client. Null while the subscription is live.
   */
  get error(): Error | null {
    return this.#error;
  }

  /**
   * Everything the channel broadcasts or transmits to this subscription. It
   * ends when the subscription is unsubscribed, rejected, or the client stops,
   * once the last callback has returned — `error` says which it was.
   *
   * Every call reads the same queue, so a subscription is read in one place: a
   * second `for await` over it would take turns with the first rather than see
   * every message.
   */
  messages(): AsyncIterableIterator<Message> {
    if (this.#options.onMessage !== undefined) {
      throw new TypeError(
        "actioncable: this subscription's messages already go to its onMessage callback",
      );
    }

    const messages = this.#messages;

    return {
      next: () => messages.next(),
      [Symbol.asyncIterator]() {
        return this;
      },
    };
  }

  [Symbol.asyncIterator](): AsyncIterableIterator<Message> {
    return this.messages();
  }

  /**
   * Invokes an action on the channel — the equivalent of the JavaScript
   * client's `perform`. `data` must encode to a JSON object, and may be left
   * out.
   */
  async perform(action: string, data?: unknown, options?: SendOptions): Promise<void> {
    await this.#host.sendMessage(this.#identifier, performPayload(action, data), options);
  }

  /**
   * Delivers data to the channel as-is, without naming an action. Rails routes
   * it to the channel's `receive` method.
   */
  async send(data: unknown, options?: SendOptions): Promise<void> {
    await this.#host.sendMessage(this.#identifier, encode(data, this.#identifier), options);
  }

  /**
   * Tells the server to drop the subscription and ends its messages. The
   * command goes out on the client's own connection, so it works from a
   * teardown whose signal has already been aborted — which, at teardown, is
   * usually the one at hand.
   */
  async unsubscribe(): Promise<void> {
    const { last } = this.#host.forget(this, new UnsubscribedError());

    if (last) {
      await this.#host.sendUnsubscribe(this.#identifier);
    }
  }

  /** Resolves once the server has confirmed the subscription. */
  get confirmed(): Promise<void> {
    return this.#confirmed.promise;
  }

  /** Resolves once the channel has turned the subscription down. */
  get rejected(): Promise<void> {
    return this.#rejected.promise;
  }

  /**
   * Passes the server's verdict on. A holder that unsubscribed between the
   * registration's holders being listed and this call has nothing to hear.
   */
  confirm(reconnected: boolean): void {
    if (this.#closed) {
      return;
    }

    // The callback is queued before the verdict is published: a subscribe woken
    // by the verdict may unsubscribe at once, and that must not get ahead of
    // the callback for the event that woke it.
    if (this.#options.onConnected !== undefined) {
      const onConnected = this.#options.onConnected;
      this.#callbacks.dispatch(() => onConnected(reconnected));
    }
    this.#confirmed.resolve();
  }

  reject(): void {
    this.#callbacks.dispatch(this.#options.onRejected);
    this.#rejected.resolve();
    this.close(this.rejection());
  }

  rejection(): RejectedError {
    return new RejectedError(this.#identifier);
  }

  disconnect(willReconnect: boolean): void {
    if (this.#options.onDisconnected !== undefined) {
      const onDisconnected = this.#options.onDisconnected;
      this.#callbacks.dispatch(() => onDisconnected(willReconnect));
    }
  }

  /** Takes a message, or answers false when the buffer is full. */
  deliver(message: Message): boolean {
    // A closed subscription has nothing left to receive, and nothing to report.
    if (this.#closed) {
      return true;
    }

    return this.#messages.push(message);
  }

  /**
   * Ends the subscription for the reason given. Deliveries stop at once; the
   * messages end from the callback queue, after the callbacks already on it
   * have run, so a reader that sees the iteration finish knows no callback is
   * behind it.
   */
  close(reason: Error): void {
    if (!this.#closed) {
      this.#closed = true;
      this.#error = reason;
    }

    this.#callbacks.stop();
  }

  async #deliverToCallback(onMessage: (message: Message) => void | Promise<void>): Promise<void> {
    for (;;) {
      const result = await this.#messages.next();
      if (result.done === true) {
        return;
      }

      await onMessage(result.value);
    }
  }
}

/**
 * The payload of a `perform`: the action, then the caller's data. The action
 * goes first and wins, so data carrying an `action` of its own can't rename
 * the one being performed.
 */
function performPayload(action: string, data: unknown): string {
  const fields: Record<string, unknown> = { action, ...objectFrom(action, data) };
  fields.action = action;

  return JSON.stringify(fields);
}

function objectFrom(action: string, data: unknown): Record<string, unknown> {
  if (data === undefined || data === null) {
    return {};
  }

  const decoded: unknown = JSON.parse(encode(data, action));
  if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
    throw new TypeError(`actioncable: data for ${JSON.stringify(action)} must be a JSON object`);
  }

  return decoded as Record<string, unknown>;
}

function encode(data: unknown, what: string): string {
  let encoded: string | undefined;
  try {
    encoded = JSON.stringify(data);
  } catch (cause) {
    throw new TypeError(`actioncable: encoding data for ${what}`, { cause });
  }

  if (encoded === undefined) {
    throw new TypeError(`actioncable: data for ${what} does not encode to JSON`);
  }

  return encoded;
}
