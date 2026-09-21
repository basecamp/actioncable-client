import { createServer, type IncomingMessage, type Server } from "node:http";
import type { Duplex } from "node:stream";
import { AddressInfo } from "node:net";
import { applyMask, OPCODE, type Frame } from "../src/transport/rfc6455/frames.js";
import { acceptKey } from "../src/transport/rfc6455/handshake.js";
import { SocketReader } from "../src/transport/rfc6455/reader.js";

/** How long the loopback server waits for something that should already have happened. */
export const WAIT = 2_000;

/**
 * What the server does with an opening request. Everything but `upgrade` is
 * one of the ways a real server says no.
 */
export type Reception = "upgrade" | "bad-accept" | "refuse" | "redirect";

/**
 * Speaks just enough of the server side of RFC 6455 to exercise the transport:
 * it completes the handshake by hand and then hands the raw socket over.
 *
 * It answers on the `upgrade` event whatever the request asks for, because
 * that is the only event Node raises for a request carrying `Upgrade:` — so a
 * 404 or a redirect is written onto the same socket rather than served from a
 * request handler.
 */
export class LoopbackServer {
  reception: Reception = "upgrade";

  readonly #server: Server;
  readonly #accepted: Peer[] = [];
  readonly #sockets: Duplex[] = [];
  #waiting: (() => void) | null = null;

  private constructor(server: Server) {
    this.#server = server;
    server.on("upgrade", (request, socket, head) => this.#receive(request, socket, head));
  }

  static start(): Promise<LoopbackServer> {
    const server = createServer();
    const loopback = new LoopbackServer(server);

    return new Promise((resolve) => {
      server.listen(0, "127.0.0.1", () => resolve(loopback));
    });
  }

  get url(): string {
    const { port } = this.#server.address() as AddressInfo;

    return `ws://127.0.0.1:${port}/cable`;
  }

  get httpURL(): string {
    const { port } = this.#server.address() as AddressInfo;

    return `http://127.0.0.1:${port}/cable`;
  }

  async accept(): Promise<Peer> {
    const deadline = Date.now() + WAIT;

    for (;;) {
      const peer = this.#accepted.shift();
      if (peer !== undefined) {
        return peer;
      }
      if (Date.now() >= deadline) {
        throw new Error("no client connected");
      }

      await Promise.race([
        new Promise<void>((resolve) => {
          this.#waiting = resolve;
        }),
        sleep(10),
      ]);
      this.#waiting = null;
    }
  }

  stop(): Promise<void> {
    // An upgraded socket is no longer the server's to close, so the sockets
    // are destroyed by hand: `close` would otherwise wait for them for ever.
    for (const socket of this.#sockets.splice(0)) {
      socket.destroy();
    }

    return new Promise((resolve) => {
      this.#server.closeAllConnections();
      this.#server.close(() => resolve());
    });
  }

  #receive(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    socket.on("error", () => {});
    this.#sockets.push(socket);

    if (this.reception === "refuse") {
      socket.end(response(404, "Not Found", "no cable here"));
      return;
    }
    if (this.reception === "redirect") {
      socket.end(response(302, "Found", "", ["Location: /elsewhere"]));
      return;
    }

    const key = request.headers["sec-websocket-key"] ?? "";
    const accepted = this.reception === "bad-accept" ? "obviously-wrong" : acceptKey(key);

    const lines = [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accepted}`,
    ];
    const offered = request.headers["sec-websocket-protocol"];
    if (offered !== undefined && offered !== "") {
      lines.push(`Sec-WebSocket-Protocol: ${(offered.split(",")[0] ?? "").trim()}`);
    }
    socket.write(`${lines.join("\r\n")}\r\n\r\n`);

    if (head.length > 0) {
      socket.unshift(head);
    }

    this.#accepted.push(new Peer(request, socket));
    this.#waiting?.();
  }
}

function response(code: number, text: string, body: string, extra: string[] = []): string {
  const lines = [
    `HTTP/1.1 ${code} ${text}`,
    "Content-Type: text/plain; charset=utf-8",
    `Content-Length: ${Buffer.byteLength(body)}`,
    "Connection: close",
    ...extra,
  ];

  return `${lines.join("\r\n")}\r\n\r\n${body}`;
}

/** The server's end of one connection, in raw frames. */
export class Peer {
  readonly request: IncomingMessage;

  readonly #socket: Duplex;
  readonly #reader: SocketReader;

  constructor(request: IncomingMessage, socket: Duplex) {
    this.request = request;
    this.#socket = socket;
    this.#reader = new SocketReader(socket);
  }

  header(name: string): string {
    const value = this.request.headers[name.toLowerCase()];

    if (Array.isArray(value)) {
      return value.join(", ");
    } else {
      return value ?? "";
    }
  }

  async read(): Promise<string> {
    const frame = await this.readFrame();
    if (frame.opcode !== OPCODE.text) {
      throw new Error(`expected a text frame, got 0x${frame.opcode.toString(16)}`);
    }

    return frame.payload.toString("utf8");
  }

  async readFrame(): Promise<Frame> {
    const signal = AbortSignal.timeout(WAIT);
    const header = await this.#reader.readExactly(2, signal);
    const first = header[0] as number;
    const second = header[1] as number;

    if ((second & 0x80) === 0) {
      throw new Error("client sent an unmasked frame");
    }

    let length = second & 0x7f;
    if (length === 126) {
      length = (await this.#reader.readExactly(2, signal)).readUInt16BE(0);
    } else if (length === 127) {
      length = Number((await this.#reader.readExactly(8, signal)).readBigUInt64BE(0));
    }

    const mask = await this.#reader.readExactly(4, signal);
    const payload = Buffer.from(await this.#reader.readExactly(length, signal));
    applyMask(mask, payload);

    return { final: (first & 0x80) !== 0, opcode: first & 0x0f, payload };
  }

  write(opcode: number, payload: Buffer | string = Buffer.alloc(0)): void {
    this.writeFragment(opcode, payload, true);
  }

  writeFragment(opcode: number, payload: Buffer | string, final: boolean): void {
    const bytes = typeof payload === "string" ? Buffer.from(payload, "utf8") : payload;
    const header: number[] = [final ? 0x80 | opcode : opcode];

    if (bytes.length <= 125) {
      header.push(bytes.length);
      this.#write(Buffer.concat([Buffer.from(header), bytes]));
      return;
    }

    if (bytes.length <= 0xffff) {
      header.push(126);
      const extended = Buffer.allocUnsafe(2);
      extended.writeUInt16BE(bytes.length);
      this.#write(Buffer.concat([Buffer.from(header), extended, bytes]));
      return;
    }

    header.push(127);
    const extended = Buffer.allocUnsafe(8);
    extended.writeBigUInt64BE(BigInt(bytes.length));
    this.#write(Buffer.concat([Buffer.from(header), extended, bytes]));
  }

  /** Sends a frame the way only a client is allowed to: masked. */
  writeMasked(opcode: number, payload: string): void {
    const bytes = Buffer.from(payload, "utf8");
    const mask = Buffer.from([1, 2, 3, 4]);
    const masked = Buffer.from(bytes);
    applyMask(mask, masked);

    const header = Buffer.from([0x80 | opcode, 0x80 | bytes.length]);
    this.#write(Buffer.concat([header, mask, masked]));
  }

  /** Hangs up the underlying socket, which is what a peer going away looks like. */
  end(): void {
    this.#socket.end();
  }

  /** Counts the close frames the client sends before it goes away. */
  async closeFrames(): Promise<number> {
    let closes = 0;

    for (;;) {
      try {
        const frame = await this.readFrame();
        if (frame.opcode === OPCODE.close) {
          closes += 1;
        }
      } catch {
        return closes;
      }
    }
  }

  #write(bytes: Buffer): void {
    if (this.#socket.writable) {
      this.#socket.write(bytes);
    }
  }
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}
