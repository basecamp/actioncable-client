import { defaultTransport } from "./default-transport.js";
import {
  AbortedError,
  ActionCableError,
  AlreadyConnectedError,
  ClosedError,
  DisconnectError,
  GaveUpError,
  NoProtocolsError,
  NotConnectedError,
  StaleConnectionError,
  UnsupportedSubprotocolError,
} from "./errors.js";
import { Deferred } from "./internal/deferred.js";
import { Mutex } from "./internal/mutex.js";
import { delay, whenAborted } from "./internal/signal.js";
import { identifierKey, type Identifier } from "./identifier.js";
import { silentLogger, type Logger } from "./logger.js";
import {
  DEFAULTS,
  type Backoff,
  type ClientOptions,
  type SendOptions,
  type SubscribeOptions,
} from "./options.js";
import { V1JSON } from "./protocol-v1-json.js";
import { SUBPROTOCOL_UNSUPPORTED, type Command, type Incoming, type Protocol } from "./protocol.js";
import { Subscription, type SubscriptionHost } from "./subscription.js";
import type { Connection, HeaderInit, Transport } from "./transport.js";

/**
 * The server's one subscription for an identifier, and every `Subscription`
 * here that shares it. Rails keeps one subscription per identifier per
 * connection and says nothing to a second subscribe for it, so the subscribe
 * command, its verdict, and the retries until then belong to the identifier
 * rather than to each holder.
 */
class Registration {
  holders: Subscription[] = [];

  /**
   * `pending` is set while a subscribe is out on the connection in hand with
   * no verdict yet, `confirmed` once the server said yes on it. Both clear
   * when the connection drops: the next one starts over.
   */
  pending = true;
  confirmed = false;
}

/**
 * Owns one connection to an Action Cable server and the subscriptions running
 * over it. Build one, start it with `connect`, and hang up with `close`.
 *
 * ```ts
 * const client = new Client("wss://example.com/cable");
 * await client.connect();
 *
 * const room = await client.subscribe({ channel: "RoomChannel", params: { id: 42 } });
 * await room.perform("speak", { body: "Hello!" });
 * ```
 */
export class Client implements SubscriptionHost {
  readonly #url: string;
  readonly #transport: Transport;
  readonly #protocols: Protocol[];
  readonly #headers: Headers;
  readonly #headersFor?: (signal?: AbortSignal) => HeaderInit | Promise<HeaderInit>;
  readonly #stopOnError?: (error: unknown) => boolean;
  readonly #logger: Logger;

  readonly #staleAfter: number;
  readonly #subscribeRetry: number;
  readonly #backoff: Backoff;
  readonly #maxAttempts: number;
  readonly #messageBuffer: number;

  #connection: Connection | null = null;
  /** The protocol the server picked for the connection in hand. */
  #protocol: Protocol | null = null;
  #subscriptions = new Map<string, Registration>();
  #attempts = 0;
  /**
   * Why the latest attempt failed, kept so a `connect` that gives up waiting
   * can say what it was waiting on.
   */
  #lastError: unknown;
  #reconnected = false;
  #welcomed = false;
  #everWelcomed = false;
  #stopped = false;
  #failure: Error | null = null;
  #run: AbortController | null = null;

  /** Serializes writes, so nothing gets a frame out mid-resubscribe. */
  readonly #writing = new Mutex();

  readonly #connected = new Deferred();
  readonly #finished = new Deferred();

  constructor(url: string, options: ClientOptions = {}) {
    this.#url = url;
    this.#transport = options.transport ?? defaultTransport();
    this.#protocols = [
      ...(options.additionalProtocols ?? []),
      ...(options.protocols ?? [new V1JSON()]),
    ];
    this.#headersFor = options.headersFor;
    this.#stopOnError = options.stopOnError;
    this.#logger = options.logger ?? silentLogger;

    this.#staleAfter = options.staleAfter ?? DEFAULTS.staleAfter;
    this.#subscribeRetry = options.subscribeRetry ?? DEFAULTS.subscribeRetry;
    this.#backoff = options.backoff ?? DEFAULTS.backoff;
    this.#maxAttempts = options.maxAttempts ?? DEFAULTS.maxAttempts;
    this.#messageBuffer = options.messageBuffer ?? DEFAULTS.messageBuffer;

    this.#headers = new Headers(options.headers);
    if (options.cookie !== undefined) {
      this.#headers.set("Cookie", options.cookie);
    }
    if (options.origin !== undefined) {
      this.#headers.set("Origin", options.origin);
    }
    this.#assumeOrigin();
  }

  /** The endpoint this client dials. */
  get url(): string {
    return this.#url;
  }

  /** Whether a connection is up and welcomed. */
  get connected(): boolean {
    return this.#welcomed && this.#connection !== null;
  }

  /**
   * Resolves when the client has stopped for good — closed, told by the server
   * not to come back, out of attempts, or unable to connect in the first place
   * — and will neither reconnect nor deliver anything more. `error` says why.
   */
  get done(): Promise<void> {
    return this.#finished.promise;
  }

  /**
   * Why the client stopped, and null while it is still running or has yet to
   * be started. One of `ClosedError`, `GaveUpError`,
   * `UnsupportedSubprotocolError`, `NoProtocolsError`, a `DisconnectError`, an
   * error `stopOnError` recognized, or the `AbortedError` a failed `connect`
   * ended with.
   */
  get error(): Error | null {
    if (this.#stopped) {
      return this.#whyStopped();
    } else {
      return null;
    }
  }

  /**
   * Starts the client and returns once the server has sent its welcome. Failed
   * attempts are retried until that happens, the signal is aborted, the server
   * tells us not to come back, or `stopOnError` recognizes one as terminal.
   *
   * The signal bounds the wait, not a connection that got through: that lives
   * until `close`. A `connect` that rejects leaves the client stopped, with
   * nothing running behind it, so a client that failed to connect is one to
   * throw away. The one exception is `AlreadyConnectedError`, which says the
   * client was running fine before the call and still is.
   */
  async connect(options: { signal?: AbortSignal } = {}): Promise<void> {
    if (this.#stopped) {
      throw this.#whyStopped();
    }
    if (this.#run !== null) {
      throw new AlreadyConnectedError();
    }

    const run = new AbortController();
    this.#run = run;
    void this.#loop(run.signal);

    const signal = options.signal;
    const { aborted, cancel } = whenAborted(signal);
    try {
      const outcome = await Promise.race([
        this.#connected.promise.then(() => "connected" as const),
        this.#finished.promise.then(() => "stopped" as const),
        aborted.then(() => "aborted" as const),
      ]);

      if (outcome === "stopped") {
        throw this.#whyStopped();
      }
      if (outcome === "aborted" && signal !== undefined) {
        await this.#giveUpWaiting(signal);
      }
    } finally {
      cancel();
    }
  }

  /**
   * Stops a client whose `connect` ran out of time, unless the welcome landed
   * in the same instant, in which case the connection is kept.
   */
  async #giveUpWaiting(signal: AbortSignal): Promise<void> {
    if (this.#everWelcomed) {
      return;
    }

    this.#markStopped(new AbortedError(signal.reason, this.#lastError));
    await this.#awaitStopped();

    throw this.#whyStopped();
  }

  /**
   * Subscribes to a channel and returns once the server confirms it. The
   * subscription outlives reconnects — it is resubscribed automatically — so
   * it stays valid until `unsubscribe`.
   *
   * Subscribing to an identifier the client already holds shares the server's
   * one subscription for it instead of asking for another, which Rails would
   * ignore. Every subscription sharing an identifier gets every message, and
   * the server hears unsubscribe from the last one to go.
   *
   * It rejects with a `RejectedError` when the channel turns the subscription
   * down.
   */
  async subscribe(identifier: Identifier, options: SubscribeOptions = {}): Promise<Subscription> {
    const key = identifierKey(identifier);

    if (this.#stopped) {
      throw this.#whyStopped();
    }
    if (this.#run === null) {
      throw new NotConnectedError();
    }

    const subscription = new Subscription(this, key, this.#messageBuffer, options, this.#logger);
    let registration = this.#subscriptions.get(key);
    const shared = registration !== undefined;
    if (registration === undefined) {
      registration = new Registration();
      this.#subscriptions.set(key, registration);
    }
    registration.holders.push(subscription);

    if (registration.confirmed) {
      // The server said yes to this identifier on the connection in hand and
      // won't say so again, so the new holder is as confirmed as the rest.
      subscription.confirm(false);
      return subscription;
    }

    // A shared identifier's subscribe is already out, or goes out with the next
    // welcome, and its verdict is this subscription's too.
    if (!shared) {
      try {
        await this.#send({ name: "subscribe", identifier: key }, options);
      } catch (error) {
        // Nothing to do about it here: the connection will subscribe again as
        // soon as it is welcomed back.
        this.#logger.log(`actioncable: subscribing to ${key}: ${describe(error)}`);
      }
    }

    return await this.#awaitVerdict(subscription, options.signal);
  }

  async #awaitVerdict(
    subscription: Subscription,
    signal: AbortSignal | undefined,
  ): Promise<Subscription> {
    const { aborted, cancel } = whenAborted(signal);
    try {
      const outcome = await Promise.race([
        subscription.confirmed.then(() => "confirmed" as const),
        subscription.rejected.then(() => "rejected" as const),
        this.#finished.promise.then(() => "stopped" as const),
        aborted.then(() => "aborted" as const),
      ]);

      switch (outcome) {
        case "confirmed":
          return subscription;
        case "rejected": {
          const rejection = subscription.rejection();
          this.forget(subscription, rejection);
          throw rejection;
        }
        case "stopped": {
          const failure = this.#whyStopped();
          this.forget(subscription, failure);
          throw failure;
        }
        default: {
          const reason: unknown = signal?.reason;
          await this.#abandon(subscription, asError(reason));
          throw reason;
        }
      }
    } finally {
      cancel();
    }
  }

  /**
   * Hangs up, stops reconnecting, and ends every subscription's messages. It
   * is safe to call from a subscription callback, and safe to call twice.
   */
  async close(): Promise<void> {
    this.#markStopped(new ClosedError());
    await this.#awaitStopped();
  }

  /**
   * Forgets a subscription its caller gave up waiting on. When it was the last
   * holder of an identifier the server has heard a subscribe for, the server
   * is told to let go, or it would keep the subscription and ignore the next
   * subscribe for it as a duplicate. The connection may well be gone by now,
   * and then there is nothing to tell.
   *
   * The caller's signal is what just aborted, so the unsubscribe goes out on
   * the client's own. It is sent before returning rather than in the
   * background so a subscribe for the same identifier that follows can't get
   * ahead of it.
   */
  async #abandon(subscription: Subscription, reason: Error): Promise<void> {
    const { last, heard } = this.forget(subscription, reason);

    if (last && heard) {
      try {
        await this.sendUnsubscribe(subscription.key);
      } catch (error) {
        this.#logger.log(`actioncable: unsubscribing from ${subscription.key}: ${describe(error)}`);
      }
    }
  }

  // What a Subscription needs of the client that owns it.

  async sendMessage(identifier: string, data: string, options?: SendOptions): Promise<void> {
    await this.#send({ name: "message", identifier, data }, options);
  }

  async sendUnsubscribe(identifier: string): Promise<void> {
    await this.#send({ name: "unsubscribe", identifier }, { signal: this.#run?.signal });
  }

  /**
   * Drops a subscription and reports whether it was the last one holding that
   * identifier, which is when the server needs to hear about it, and whether
   * the server has heard a subscribe for it on the connection in hand at all.
   */
  forget(subscription: Subscription, reason: Error): { last: boolean; heard: boolean } {
    const registration = this.#subscriptions.get(subscription.key);
    const remaining = (registration?.holders ?? []).filter((held) => held !== subscription);
    const last = remaining.length === 0;
    const heard = registration !== undefined && (registration.pending || registration.confirmed);

    if (registration !== undefined) {
      if (last) {
        this.#subscriptions.delete(subscription.key);
      } else {
        registration.holders = remaining;
      }
    }

    subscription.close(reason);

    return { last, heard };
  }

  // The connection loop.

  async #loop(signal: AbortSignal): Promise<void> {
    try {
      for (;;) {
        const failure = await this.#session(signal);
        if (!this.#stopped) {
          this.#logger.log(`actioncable: connection to ${this.#url} ended: ${describe(failure)}`);
        }

        if (this.#stopped || signal.aborted) {
          return;
        }

        await delay(this.#reconnectDelay(), signal);
        if (signal.aborted) {
          return;
        }
      }
    } catch (error) {
      this.#markStopped(asError(error));
    } finally {
      this.#closeSubscriptions();
      this.#finished.resolve();
    }
  }

  /** Runs one connection from dial to hangup, and answers with why it ended. */
  async #session(signal: AbortSignal): Promise<unknown> {
    if (this.#protocols.length === 0) {
      return this.#stop(new NoProtocolsError());
    }

    let headers: Headers;
    try {
      headers = await this.#dialHeaders(signal);
    } catch (error) {
      return this.#failed(signal, error);
    }

    let connection: Connection;
    try {
      connection = await this.#transport.dial(this.#url, {
        subprotocols: [...this.#subprotocols(), SUBPROTOCOL_UNSUPPORTED],
        headers,
        signal,
      });
    } catch (error) {
      return this.#failed(signal, error);
    }

    const protocol = this.#protocols.find((known) => known.subprotocol === connection.subprotocol);
    if (protocol === undefined) {
      await hangUp(connection);
      return this.#stop(
        new UnsupportedSubprotocolError(connection.subprotocol, this.#subprotocols()),
      );
    }

    this.#connection = connection;
    this.#protocol = protocol;

    const guarantor = setInterval(
      () => void this.#guaranteeSubscriptions(signal),
      this.#subscribeRetry,
    );
    try {
      return this.#failed(signal, await this.#receive(signal, connection, protocol));
    } finally {
      clearInterval(guarantor);
      this.#disconnect();
      await hangUp(connection);
    }
  }

  /**
   * Records why an attempt ended and, when that was the last one allowed,
   * stops the client. It runs ahead of the disconnect so the subscriptions
   * hear that the client is not coming back rather than that it is.
   */
  #failed(signal: AbortSignal, failure: unknown): unknown {
    if (this.#stopped || signal.aborted) {
      return failure;
    }

    if (this.#stopOnError?.(failure) === true) {
      return this.#stop(failure);
    }

    this.#attempts += 1;
    this.#lastError = failure;
    if (this.#attempts === this.#maxAttempts) {
      this.#stop(new GaveUpError(failure));
    }

    return failure;
  }

  /** Names every protocol the client can speak, most preferred first. */
  #subprotocols(): string[] {
    return this.#protocols.map((protocol) => protocol.subprotocol);
  }

  /**
   * Reads until the connection dies. A connection that has gone quiet for
   * longer than `staleAfter` is dead: the server beats a ping every three
   * seconds.
   *
   * Every read gets its own deadline, and its own controller rather than an
   * `AbortSignal.any` over the run's: the run's signal outlives tens of
   * thousands of reads, and each composite would hang another dependent off it
   * until the garbage collector got round to it.
   */
  async #receive(
    signal: AbortSignal,
    connection: Connection,
    protocol: Protocol,
  ): Promise<unknown> {
    for (;;) {
      const reading = new AbortController();
      const giveUp = (): void => reading.abort(signal.reason);
      signal.addEventListener("abort", giveUp, { once: true });
      let quiet = false;
      const deadline = setTimeout(() => {
        quiet = true;
        reading.abort();
      }, this.#staleAfter);

      let payload: string;
      try {
        payload = await connection.read({ signal: reading.signal });
      } catch (error) {
        // A deadline the run's signal didn't cause is our own staleness
        // timeout rather than a cancellation.
        if (quiet && !signal.aborted) {
          return new StaleConnectionError(this.#staleAfter, { cause: error });
        } else {
          return error;
        }
      } finally {
        clearTimeout(deadline);
        signal.removeEventListener("abort", giveUp);
      }

      const failure = await this.#dispatch(signal, protocol, payload);
      if (failure !== null) {
        return failure;
      }
    }
  }

  async #dispatch(signal: AbortSignal, protocol: Protocol, payload: string): Promise<unknown> {
    let incoming: Incoming;
    try {
      incoming = protocol.decode(payload);
    } catch (error) {
      this.#logger.log(`actioncable: dropping undecodable frame: ${describe(error)}`);
      return null;
    }

    switch (incoming.kind) {
      case "welcome":
        await this.#welcome(signal);
        break;
      case "ping":
        // The frame itself is the heartbeat, and reading it already reset the
        // staleness deadline.
        break;
      case "disconnect":
        return this.#hangUp(incoming);
      case "confirmation":
        this.#confirm(incoming.identifier);
        break;
      case "rejection":
        this.#reject(incoming.identifier);
        break;
      case "message":
        this.#deliver(incoming);
        break;
    }

    return null;
  }

  /**
   * Resets the connection's health and resubscribes everything, the way the
   * server expects after every fresh connection.
   */
  async #welcome(signal: AbortSignal): Promise<void> {
    await this.#writing.locked(async () => {
      this.#attempts = 0;
      this.#welcomed = true;
      this.#reconnected = this.#everWelcomed;
      this.#everWelcomed = true;

      const identifiers: string[] = [];
      for (const [identifier, registration] of this.#subscriptions) {
        registration.pending = true;
        registration.confirmed = false;
        identifiers.push(identifier);
      }

      this.#connected.resolve();

      await this.#resubscribe(signal, identifiers);
    });
  }

  /**
   * Resends subscribe commands until they are confirmed. A subscribe sent
   * while the server was still setting the connection up is simply dropped on
   * the floor, so unconfirmed means unheard.
   */
  async #guaranteeSubscriptions(signal: AbortSignal): Promise<void> {
    await this.#writing.locked(() => this.#resubscribe(signal, this.#pendingIdentifiers()));
  }

  /**
   * Sends a subscribe for each identifier. The caller holds the write lock
   * from before the identifiers were listed until this returns, so nothing
   * else can get a command out in between. Otherwise an unsubscribe that lands
   * mid-list could write its unsubscribe ahead of the subscribe for the same
   * identifier, and the server would end up holding a subscription nobody here
   * knows about — one it would silently ignore every later subscribe for.
   */
  async #resubscribe(signal: AbortSignal, identifiers: string[]): Promise<void> {
    for (const identifier of identifiers) {
      try {
        await this.#write({ name: "subscribe", identifier }, { signal });
      } catch (error) {
        this.#logger.log(`actioncable: resubscribing to ${identifier}: ${describe(error)}`);
      }
    }
  }

  #pendingIdentifiers(): string[] {
    const pending: string[] = [];
    for (const [identifier, registration] of this.#subscriptions) {
      if (registration.pending) {
        pending.push(identifier);
      }
    }

    return pending;
  }

  #confirm(identifier: string): void {
    const registration = this.#subscriptions.get(identifier);

    // Only an identifier waiting on a verdict has news. The server can confirm
    // twice when a retried subscribe crosses the first confirmation.
    if (registration === undefined || !registration.pending) {
      return;
    }

    registration.pending = false;
    registration.confirmed = true;

    for (const subscription of registration.holders) {
      subscription.confirm(this.#reconnected);
    }
  }

  #reject(identifier: string): void {
    const holders = this.#subscriptions.get(identifier)?.holders ?? [];
    this.#subscriptions.delete(identifier);

    for (const subscription of holders) {
      subscription.reject();
    }
  }

  #deliver(incoming: Incoming): void {
    const holders = this.#subscriptions.get(incoming.identifier)?.holders ?? [];
    if (holders.length === 0) {
      this.#logger.log(`actioncable: no subscription for ${incoming.identifier}, dropping message`);
      return;
    }

    for (const subscription of holders) {
      if (!subscription.deliver(incoming.message)) {
        this.#logger.log(
          `actioncable: message buffer full for ${incoming.identifier}, dropping message`,
        );
      }
    }
  }

  #hangUp(incoming: Incoming): unknown {
    const disconnect = new DisconnectError(incoming.reason, incoming.reconnect);

    if (incoming.reconnect) {
      return disconnect;
    } else {
      return this.#stop(disconnect);
    }
  }

  /** Tears down the current connection and tells every subscription. */
  #disconnect(): void {
    this.#connection = null;
    this.#protocol = null;
    this.#welcomed = false;
    for (const registration of this.#subscriptions.values()) {
      registration.pending = false;
      registration.confirmed = false;
    }

    const willReconnect = !this.#stopped;
    for (const subscription of this.#allSubscriptions()) {
      subscription.disconnect(willReconnect);
    }
  }

  async #send(command: Command, options?: SendOptions): Promise<void> {
    await this.#writing.locked(() => this.#write(command, options));
  }

  /** Puts one command on the connection. The caller holds the write lock. */
  async #write(command: Command, options?: SendOptions): Promise<void> {
    const connection = this.#connection;
    const protocol = this.#protocol;

    // Before the welcome the server hasn't finished setting the connection up
    // and throws away whatever it receives, so there is nowhere to send yet.
    if (connection === null || protocol === null || !this.#welcomed) {
      throw new NotConnectedError();
    }

    await connection.write(protocol.encode(command), { signal: options?.signal });
  }

  #closeSubscriptions(): void {
    const subscriptions = this.#allSubscriptions();
    this.#subscriptions = new Map();

    const failure = this.#whyStopped();
    for (const subscription of subscriptions) {
      subscription.close(failure);
    }
  }

  #allSubscriptions(): Subscription[] {
    return [...this.#subscriptions.values()].flatMap((registration) => registration.holders);
  }

  /** Shuts the client down for good: some failures don't get better by dialing again. */
  #stop(reason: unknown): unknown {
    this.#markStopped(asError(reason));
    this.#run?.abort();

    return reason;
  }

  /** Marks the client stopped, unless an earlier reason already stands. */
  #markStopped(reason: Error): void {
    this.#stopped = true;
    this.#failure ??= reason;
  }

  /**
   * Hangs up whatever connection a stopped client still has open and waits
   * until nothing is running any more.
   */
  async #awaitStopped(): Promise<void> {
    const run = this.#run;
    const connection = this.#connection;

    if (run === null) {
      // Nothing was ever started, so nothing will finish it for us.
      this.#finished.resolve();
      return;
    }

    run.abort();
    if (connection !== null) {
      await hangUp(connection);
    }

    await this.#finished.promise;
  }

  #whyStopped(): Error {
    return this.#failure ?? new ClosedError();
  }

  /**
   * Doubles the delay per failed attempt, up to the longest, and spreads the
   * result over the last interval so a restarted server doesn't get every
   * client back at the same instant.
   */
  #reconnectDelay(): number {
    const doublings = Math.min(Math.max(this.#attempts - 1, 0), 16);
    const longest = Math.min(this.#backoff.initial * 2 ** doublings, this.#backoff.longest);

    return longest / 2 + Math.random() * (longest / 2);
  }

  /**
   * What the opening request carries. Without `headersFor` that is what was
   * set once, at construction; with it, what the caller says now, laid over
   * the headers already there.
   */
  async #dialHeaders(signal: AbortSignal): Promise<Headers> {
    if (this.#headersFor === undefined) {
      return this.#headers;
    }

    const current = new Headers(await this.#headersFor(signal));
    const headers = new Headers(this.#headers);
    for (const [name, value] of current) {
      headers.set(name, value);
    }

    return headers;
  }

  /**
   * Fills in an `Origin` for the opening request when none was given. Rails
   * compares `Origin` against the host it serves on and turns down anything
   * else, a request carrying no `Origin` at all included, so the Action Cable
   * URL's own origin is the one that gets in. A server behind a proxy that
   * terminates TLS sees a different scheme than the URL says, and needs
   * `origin` to say so.
   */
  #assumeOrigin(): void {
    if (this.#headers.has("Origin")) {
      return;
    }

    const origin = originOf(this.#url);
    if (origin !== null) {
      this.#headers.set("Origin", origin);
    }
  }
}

function originOf(rawURL: string): string | null {
  let endpoint: URL;
  try {
    endpoint = new URL(rawURL);
  } catch {
    return null;
  }

  switch (endpoint.protocol) {
    case "wss:":
    case "https:":
      return `https://${endpoint.host}`;
    case "ws:":
    case "http:":
      return `http://${endpoint.host}`;
    default:
      return null;
  }
}

async function hangUp(connection: Connection): Promise<void> {
  try {
    await connection.close();
  } catch {
    // Hanging up is best effort: the socket is going away either way.
  }
}

function asError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  } else {
    return new ActionCableError(String(value));
  }
}

function describe(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  } else {
    return String(error);
  }
}
