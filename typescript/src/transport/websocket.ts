import { CloseError, HandshakeError } from "../errors.js";
import { Deferred } from "../internal/deferred.js";
import { MessageQueue } from "../internal/message-queue.js";
import { whenAborted } from "../internal/signal.js";
import type { Connection, DialOptions, StatusCloser, TransferOptions } from "../transport.js";

/**
 * The platform's own `WebSocket`, behind the transport interface. It is the
 * default in a browser and in any runtime that isn't Node, and the one to
 * choose deliberately where a `node:net` socket would be wrong — a bundled
 * renderer, a service worker, React Native.
 *
 * It cannot send headers: a browser decides what an opening WebSocket request
 * carries, and neither a `Cookie` nor an `Authorization` header is the page's
 * to set. Cookies for the cable's own origin ride along by themselves; a token
 * goes in the URL's query string, or the connection is made with
 * `NodeTransport` where headers are allowed.
 */
export class WebSocketTransport {
  /** Builds the socket. Swap it to use a `WebSocket` polyfill. */
  constructor(
    private readonly open: (url: string, subprotocols: string[]) => WebSocketLike = openGlobal,
  ) {}

  async dial(url: string, options: DialOptions = {}): Promise<Connection> {
    const socket = this.open(url, options.subprotocols ?? []);
    const connection = new WebSocketConnection(socket);

    await connection.opened(options.signal);

    return connection;
  }
}

/**
 * The slice of the WHATWG `WebSocket` this transport uses. Naming it keeps the
 * package off both the DOM and the Node type libraries, either of which would
 * make it look like it only runs in one of them.
 */
export interface WebSocketLike {
  readonly protocol: string;
  binaryType: string;
  addEventListener(type: "open", listener: () => void): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  addEventListener(type: "error", listener: (event: unknown) => void): void;
  addEventListener(
    type: "close",
    listener: (event: { code: number; reason: string }) => void,
  ): void;
  send(payload: string): void;
  close(code?: number, reason?: string): void;
}

function openGlobal(url: string, subprotocols: string[]): WebSocketLike {
  const Socket = (globalThis as { WebSocket?: WebSocketConstructor }).WebSocket;
  if (Socket === undefined) {
    throw new TypeError(
      "actioncable: this runtime has no global WebSocket — pass a transport of your own",
    );
  }

  return new Socket(url, subprotocols);
}

type WebSocketConstructor = new (url: string, subprotocols: string[]) => WebSocketLike;

class WebSocketConnection implements StatusCloser {
  readonly #socket: WebSocketLike;
  readonly #incoming = new MessageQueue();
  readonly #open = new Deferred<Error | null>();
  #closed = false;

  constructor(socket: WebSocketLike) {
    this.#socket = socket;
    socket.binaryType = "arraybuffer";

    socket.addEventListener("open", () => this.#open.resolve(null));
    socket.addEventListener("message", (event) => this.#incoming.push(text(event.data)));
    socket.addEventListener("error", () => {
      // A WebSocket error event says nothing about what went wrong: the
      // handshake's status code is deliberately withheld from a page. The
      // close event right behind it carries the code, which is all there is.
      this.#open.resolve(new HandshakeError(0, "the connection could not be opened"));
    });
    socket.addEventListener("close", (event) => {
      this.#closed = true;
      this.#open.resolve(new HandshakeError(0, `closed before opening: ${event.code}`));
      this.#incoming.fail(new CloseError(event.code, event.reason));
    });
  }

  async opened(signal?: AbortSignal): Promise<void> {
    signal?.throwIfAborted();

    const { aborted, cancel } = whenAborted(signal);
    try {
      const failure = await Promise.race([
        this.#open.promise,
        aborted.then(() => asError(signal?.reason)),
      ]);

      if (failure !== null) {
        this.#socket.close();
        throw failure;
      }
    } finally {
      cancel();
    }
  }

  get subprotocol(): string {
    return this.#socket.protocol;
  }

  read(options: TransferOptions = {}): Promise<string> {
    return this.#incoming.next(options.signal);
  }

  async write(payload: string, options: TransferOptions = {}): Promise<void> {
    options.signal?.throwIfAborted();
    this.#socket.send(payload);
  }

  close(): Promise<void> {
    return this.closeWithStatus(1000);
  }

  async closeWithStatus(code: number, reason = ""): Promise<void> {
    if (!this.#closed) {
      this.#socket.close(code, reason);
    }
    this.#incoming.fail(new CloseError(code, reason));
  }
}

function text(data: unknown): string {
  if (typeof data === "string") {
    return data;
  } else if (data instanceof ArrayBuffer) {
    return new TextDecoder().decode(data);
  } else {
    return String(data);
  }
}

function asError(reason: unknown): Error {
  if (reason instanceof Error) {
    return reason;
  } else {
    return new Error(String(reason));
  }
}
