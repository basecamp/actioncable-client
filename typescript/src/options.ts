import type { Logger } from "./logger.js";
import type { Protocol } from "./protocol.js";
import type { Message } from "./message.js";
import type { HeaderInit, Transport } from "./transport.js";

/** How long a reconnect waits, and how far the wait grows. Milliseconds. */
export interface Backoff {
  initial: number;
  longest: number;
}

/**
 * Configures a client. Go passes these as functional options; the shape here
 * is one object, and every field has the same default the Go client does.
 */
export interface ClientOptions {
  /**
   * The network handler. Defaults to `NodeTransport` under Node and
   * `WebSocketTransport` everywhere else.
   */
  transport?: Transport;

  /**
   * The protocols offered during the handshake, most preferred first,
   * replacing the default of `V1JSON`. The server picks one of them and the
   * client speaks it for the rest of the connection.
   */
  protocols?: Protocol[];

  /**
   * Protocols offered ahead of the ones already there, so preferring a new
   * protocol doesn't mean restating the ones to fall back to.
   */
  additionalProtocols?: Protocol[];

  /**
   * The headers sent on the upgrade request. An Action Cable server authorizes
   * that request, so this is where a session cookie or a bearer token goes.
   */
  headers?: HeaderInit;

  /**
   * Builds the headers on every dial rather than once. A client reconnects on
   * its own for as long as it runs, which is longer than a credential that
   * expires lives, and a reconnect carrying the token the first dial used
   * would be turned down for good. What this returns is laid over the headers
   * already set, so an `origin` or a token given in `headers` survives.
   *
   * A rejection turns down that dial, and the client tries again on its
   * backoff. A `connect` that runs out of time or attempts meanwhile reports
   * the error alongside its own, so a credential that can't be built doesn't
   * hide behind a deadline.
   */
  headersFor?: (signal?: AbortSignal) => HeaderInit | Promise<HeaderInit>;

  /**
   * Recognizes a connection error that another attempt cannot repair. It sees
   * header, dial and established-connection failures. When it answers true the
   * client stops with that error instead of reconnecting.
   */
  stopOnError?: (error: unknown) => boolean;

  /** Shorthand for sending one `Cookie` header. */
  cookie?: string;

  /**
   * The `Origin` header. Rails checks it unless the server disables request
   * forgery protection, and assumes the cable URL's own origin when this is
   * left out.
   */
  origin?: string;

  /** Where the client's chatter goes. Nothing is logged by default. */
  logger?: Logger;

  /**
   * How long a connection may go without a frame before it counts as dead, in
   * milliseconds. The server beats every three seconds; the default is six
   * thousand, so two missed beats.
   */
  staleAfter?: number;

  /**
   * The reconnect delay. It starts at `initial`, doubles per failed attempt up
   * to `longest`, and is spread with jitter. Defaults to a second and half a
   * minute.
   */
  backoff?: Backoff;

  /**
   * How many connection attempts may fail in a row before the client stops
   * with a `GaveUpError`. A welcome resets the count, so it bounds an outage
   * rather than the client's lifetime. Zero, the default, keeps trying until
   * `close`.
   */
  maxAttempts?: number;

  /**
   * How often an unconfirmed subscribe command is resent, in milliseconds.
   * Defaults to five hundred, like the JavaScript client's guarantor.
   */
  subscribeRetry?: number;

  /**
   * How many messages a subscription buffers before it starts dropping them.
   * Defaults to 64.
   */
  messageBuffer?: number;
}

/**
 * Configures one subscription. The callbacks run off the connection's flow,
 * one at a time, in the order the events happened, so `close`, `subscribe` and
 * `unsubscribe` all work from inside one. The last of them has returned by the
 * time the subscription's messages end.
 */
export interface SubscribeOptions {
  /** Gives up waiting for the server to confirm the subscription. */
  signal?: AbortSignal;

  /**
   * Called every time the server confirms the subscription, including after a
   * reconnect — which is what `reconnected` reports.
   */
  onConnected?: (reconnected: boolean) => void | Promise<void>;

  /**
   * Called when the connection drops, with whether the client intends to dial
   * again.
   */
  onDisconnected?: (willReconnect: boolean) => void | Promise<void>;

  /** Called when the channel rejects the subscription. */
  onRejected?: () => void | Promise<void>;

  /**
   * Called for every message the channel sends. It is the event-shaped way to
   * read a subscription; iterating it with `for await` is the other, and a
   * subscription is read one way or the other, never both.
   */
  onMessage?: (message: Message) => void | Promise<void>;
}

/** Bounds a `perform` or a `send`. */
export interface SendOptions {
  signal?: AbortSignal;
}

export const DEFAULTS = {
  staleAfter: 6_000,
  subscribeRetry: 500,
  backoff: { initial: 1_000, longest: 30_000 },
  maxAttempts: 0,
  messageBuffer: 64,
} as const;
