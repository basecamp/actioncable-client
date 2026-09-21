/**
 * Dials the network connection a client talks over. It is the seam where a
 * WebSocket implementation plugs in: the built-in `NodeTransport` speaks
 * RFC 6455 on `node:net`, `WebSocketTransport` wraps the platform's global
 * `WebSocket`, and wrapping `ws`, a React Native socket or an in-memory pipe
 * for tests means implementing these two interfaces and nothing else.
 */
export interface Transport {
  dial(url: string, options: DialOptions): Promise<Connection>;
}

/**
 * What the client needs the transport to negotiate: the subprotocols its
 * protocols speak, and the headers that authenticate the request — a cookie or
 * a token, since an Action Cable server authorizes the upgrade request itself.
 *
 * `signal` bounds the dial.
 */
export interface DialOptions {
  subprotocols?: string[];
  headers?: HeaderEntries;
  signal?: AbortSignal;
}

/**
 * Headers as a transport receives them. A `Headers` is one, and so is a plain
 * list of pairs — which is what lets a test hand a transport a value a
 * `Headers` would refuse, and see it neutralized rather than passed on.
 */
export type HeaderEntries = Headers | Iterable<[string, string]>;

/**
 * Headers as a caller writes them. The same three shapes `new Headers()`
 * takes, named here because the global `HeadersInit` is DOM's and this package
 * builds for both.
 */
export type HeaderInit = Headers | Record<string, string> | Array<[string, string]>;

/** Bounds one read or write. */
export interface TransferOptions {
  signal?: AbortSignal;
}

/**
 * One live connection. `read` and `write` are each called one at a time, but
 * `close` may be called while either is outstanding and must interrupt it.
 */
export interface Connection {
  /** What the server negotiated, empty if it named none. */
  readonly subprotocol: string;

  /**
   * The next complete message. It rejects once the connection is unusable,
   * including when the signal is aborted.
   */
  read(options?: TransferOptions): Promise<string>;

  /** Sends one text message. */
  write(payload: string, options?: TransferOptions): Promise<void>;

  close(): Promise<void>;
}

/**
 * A connection that can say why it is hanging up. `close` sends a close frame
 * with 1000 Normal Closure; `closeWithStatus` sends one with the code and
 * reason given, for a caller with something to tell the server. Both built-in
 * transports' connections implement it.
 */
export interface StatusCloser extends Connection {
  closeWithStatus(code: number, reason?: string): Promise<void>;
}

export function isStatusCloser(connection: Connection): connection is StatusCloser {
  return typeof (connection as StatusCloser).closeWithStatus === "function";
}
