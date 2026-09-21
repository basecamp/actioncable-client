import net from "node:net";
import tls from "node:tls";
import type { Duplex } from "node:stream";
import { MessageTooBigError, ProtocolViolationError } from "../errors.js";
import { Mutex } from "../internal/mutex.js";
import { whenAborted } from "../internal/signal.js";
import type { Connection, DialOptions, StatusCloser, TransferOptions } from "../transport.js";
import {
  closeErrorFrom,
  closePayload,
  closeReply,
  encodeFrame,
  CLOSE_NORMAL,
  OPCODE,
  type Frame,
} from "./rfc6455/frames.js";
import { nonce, parseResponse, upgradeRequest, verifyUpgrade } from "./rfc6455/handshake.js";
import { SocketReader } from "./rfc6455/reader.js";

/** How long the response head may be before we stop reading it in. */
const MAX_RESPONSE_HEAD = 64 * 1024;

export interface NodeTransportOptions {
  /** Bounds the upgrade request, in milliseconds. Defaults to ten seconds. */
  handshakeTimeout?: number;

  /**
   * Bounds a single write when the caller's signal doesn't, in milliseconds.
   * Defaults to ten seconds.
   */
  writeTimeout?: number;

  /** The largest message accepted, in bytes. Defaults to 8 MB. */
  maxMessageSize?: number;

  /** Passed to `tls.connect` for a `wss://` connection. */
  tls?: tls.ConnectionOptions;

  /** Passed to `net.connect` alongside the host and port from the URL. */
  socket?: Omit<net.TcpNetConnectOpts, "host" | "port">;
}

/**
 * The built-in transport under Node: an RFC 6455 client written on `node:net`
 * and `node:tls`, so the package carries no dependencies. It does the upgrade
 * handshake, masks what it sends, answers pings, reassembles fragmented
 * messages, and — unlike the platform's `WebSocket` — sends the headers it is
 * handed, which is what a cookie or a bearer token needs.
 */
export class NodeTransport {
  readonly #handshakeTimeout: number;
  readonly #writeTimeout: number;
  readonly #maxMessageSize: number;
  readonly #tls: tls.ConnectionOptions;
  readonly #socket: Omit<net.TcpNetConnectOpts, "host" | "port">;

  constructor(options: NodeTransportOptions = {}) {
    this.#handshakeTimeout = options.handshakeTimeout ?? 10_000;
    this.#writeTimeout = options.writeTimeout ?? 10_000;
    this.#maxMessageSize = options.maxMessageSize ?? 8 * 1024 * 1024;
    this.#tls = options.tls ?? {};
    this.#socket = options.socket ?? {};
  }

  async dial(url: string, options: DialOptions = {}): Promise<Connection> {
    const endpoint = new URL(url);
    const { port, secure } = endpointAddress(endpoint);

    const handshake = AbortSignal.timeout(this.#handshakeTimeout);
    const signal =
      options.signal === undefined ? handshake : AbortSignal.any([options.signal, handshake]);

    const socket = await this.#open(endpoint, port, secure, signal);
    try {
      return await this.#upgrade(socket, endpoint, options, signal);
    } catch (error) {
      socket.destroy();
      throw error;
    }
  }

  #open(endpoint: URL, port: number, secure: boolean, signal: AbortSignal): Promise<Duplex> {
    const host = endpoint.hostname;

    return new Promise<Duplex>((resolve, reject) => {
      const socket = secure
        ? tls.connect({ servername: host, ...this.#tls, host, port })
        : net.connect({ ...this.#socket, host, port });

      const { aborted, cancel } = whenAborted(signal);
      let settled = false;
      const settle = (finish: () => void): void => {
        if (!settled) {
          settled = true;
          cancel();
          finish();
        }
      };

      // The listener stays on for the connection's whole life: an 'error' with
      // nobody listening takes the process down with it.
      socket.on("error", (error: Error) => {
        settle(() => reject(new Error(`actioncable: dialing ${host}:${port}`, { cause: error })));
      });
      socket.once(secure ? "secureConnect" : "connect", () => settle(() => resolve(socket)));
      void aborted.then(() =>
        settle(() => {
          socket.destroy();
          reject(asError(signal.reason));
        }),
      );
    });
  }

  async #upgrade(
    socket: Duplex,
    endpoint: URL,
    options: DialOptions,
    signal: AbortSignal,
  ): Promise<Connection> {
    const reader = new SocketReader(socket);
    const key = nonce();

    await write(
      socket,
      upgradeRequest({
        endpoint,
        key,
        subprotocols: options.subprotocols ?? [],
        headers: options.headers ?? [],
      }),
    );

    const head = await reader.readUntil("\r\n\r\n", MAX_RESPONSE_HEAD, signal);
    const response = parseResponse(head.subarray(0, head.length - 4));
    verifyUpgrade(response, key);

    return new NodeConnection(
      socket,
      reader,
      response.headers.get("sec-websocket-protocol") ?? "",
      {
        writeTimeout: this.#writeTimeout,
        maxMessageSize: this.#maxMessageSize,
      },
    );
  }
}

function endpointAddress(endpoint: URL): { port: number; secure: boolean } {
  switch (endpoint.protocol) {
    case "ws:":
    case "http:":
      return { port: Number(endpoint.port === "" ? 80 : endpoint.port), secure: false };
    case "wss:":
    case "https:":
      return { port: Number(endpoint.port === "" ? 443 : endpoint.port), secure: true };
    default:
      throw new TypeError(`actioncable: unsupported scheme ${JSON.stringify(endpoint.protocol)}`);
  }
}

interface ConnectionLimits {
  writeTimeout: number;
  maxMessageSize: number;
}

class NodeConnection implements StatusCloser {
  readonly subprotocol: string;

  readonly #socket: Duplex;
  readonly #reader: SocketReader;
  readonly #limits: ConnectionLimits;
  readonly #writing = new Mutex();

  #closeSent = false;
  #closed = false;

  constructor(socket: Duplex, reader: SocketReader, subprotocol: string, limits: ConnectionLimits) {
    this.subprotocol = subprotocol;
    this.#socket = socket;
    this.#reader = reader;
    this.#limits = limits;
  }

  async read(options: TransferOptions = {}): Promise<string> {
    const signal = options.signal;
    let message: Buffer[] = [];
    let buffered = 0;
    let fragmented = false;

    for (;;) {
      const frame = await this.#readFrame(signal);

      switch (frame.opcode) {
        case OPCODE.text:
        case OPCODE.binary:
          if (fragmented) {
            throw this.#fail(
              new ProtocolViolationError(
                "received a new data frame in the middle of a fragmented message",
              ),
            );
          }
          if (frame.final) {
            return frame.payload.toString("utf8");
          }
          message = [frame.payload];
          buffered = frame.payload.length;
          fragmented = true;
          break;

        case OPCODE.continuation:
          if (!fragmented) {
            throw this.#fail(
              new ProtocolViolationError(
                "received a continuation frame outside a fragmented message",
              ),
            );
          }
          buffered += frame.payload.length;
          if (buffered > this.#limits.maxMessageSize) {
            throw this.#fail(
              new MessageTooBigError(`a message past ${this.#limits.maxMessageSize} bytes`),
            );
          }
          message.push(frame.payload);
          if (frame.final) {
            return Buffer.concat(message).toString("utf8");
          }
          break;

        case OPCODE.ping:
          await this.#writeFrame(OPCODE.pong, frame.payload, signal);
          break;

        case OPCODE.pong:
          break;

        case OPCODE.close:
          // One close frame in reply, then the socket goes: close sees the
          // reply was already sent and won't send a second one.
          await this.#writeFrame(OPCODE.close, closeReply(frame.payload), signal).catch(() => {});
          await this.close();
          throw closeErrorFrom(frame.payload);

        default:
          throw this.#fail(
            new ProtocolViolationError(`received unknown opcode 0x${frame.opcode.toString(16)}`),
          );
      }
    }
  }

  async write(payload: string, options: TransferOptions = {}): Promise<void> {
    await this.#writeFrame(OPCODE.text, Buffer.from(payload, "utf8"), options.signal);
  }

  close(): Promise<void> {
    return this.closeWithStatus(CLOSE_NORMAL, "");
  }

  /**
   * The close frame goes out with a short deadline and the socket is destroyed
   * right after, whether or not the server answers: waiting on a peer that may
   * already be gone would hold up whoever is hanging up.
   */
  async closeWithStatus(code: number, reason = ""): Promise<void> {
    if (this.#closed) {
      return;
    }
    this.#closed = true;

    if (!this.#closeSent && this.#socket.writable) {
      this.#closeSent = true;
      await Promise.race([
        write(this.#socket, encodeFrame(OPCODE.close, closePayload(code, reason))).catch(() => {}),
        sleep(1_000),
      ]);
    }

    this.#socket.destroy();
  }

  async #readFrame(signal: AbortSignal | undefined): Promise<Frame> {
    const header = await this.#reader.readExactly(2, signal);
    const first = header[0] as number;
    const second = header[1] as number;

    const frame: Frame = {
      final: (first & 0x80) !== 0,
      opcode: first & 0x0f,
      payload: Buffer.alloc(0),
    };
    if ((first & 0x70) !== 0) {
      throw this.#fail(new ProtocolViolationError("received a frame with reserved bits set"));
    }

    // RFC 6455 §5.1: a server must not mask what it sends, and a client that
    // receives a masked frame must fail the connection.
    if ((second & 0x80) !== 0) {
      throw this.#fail(new ProtocolViolationError("received a masked frame from the server"));
    }

    let length = second & 0x7f;
    if (length === 126) {
      length = (await this.#reader.readExactly(2, signal)).readUInt16BE(0);
    } else if (length === 127) {
      const extended = (await this.#reader.readExactly(8, signal)).readBigUInt64BE(0);
      length = Number(extended & 0x7fffffffffffffffn);
    }

    if (frame.opcode >= OPCODE.close && (!frame.final || length > 125)) {
      throw this.#fail(
        new ProtocolViolationError("received a fragmented or oversized control frame"),
      );
    }
    if (length > this.#limits.maxMessageSize) {
      throw this.#fail(
        new MessageTooBigError(
          `a ${length} byte frame against a limit of ${this.#limits.maxMessageSize}`,
        ),
      );
    }

    frame.payload = await this.#reader.readExactly(length, signal);

    return frame;
  }

  async #writeFrame(
    opcode: number,
    payload: Buffer,
    signal: AbortSignal | undefined,
  ): Promise<void> {
    await this.#writing.locked(async () => {
      if (opcode === OPCODE.close) {
        this.#closeSent = true;
      }

      await write(this.#socket, encodeFrame(opcode, payload), signal, this.#limits.writeTimeout);
    });
  }

  /**
   * Fails the connection: a frame we can't trust means the peer isn't speaking
   * the protocol, and reading on would be guesswork.
   */
  #fail(error: Error): Error {
    void this.close();

    return error;
  }
}

function write(
  socket: Duplex,
  bytes: Buffer,
  signal?: AbortSignal,
  timeout?: number,
): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const { aborted, cancel } = whenAborted(signal);
    const timer =
      timeout === undefined
        ? undefined
        : setTimeout(() => {
            settle(() => reject(new Error("actioncable: writing a frame timed out")));
          }, timeout);

    const settle = (finish: () => void): void => {
      cancel();
      if (timer !== undefined) {
        clearTimeout(timer);
      }
      finish();
    };

    void aborted.then(() => settle(() => reject(asError(signal?.reason))));

    socket.write(bytes, (error) => {
      if (error) {
        settle(() => reject(new Error("actioncable: writing a frame", { cause: error })));
      } else {
        settle(resolve);
      }
    });
  });
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds).unref?.();
  });
}

function asError(reason: unknown): Error {
  if (reason instanceof Error) {
    return reason;
  } else {
    return new Error(String(reason));
  }
}
