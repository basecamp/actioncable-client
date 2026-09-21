import type { Duplex } from "node:stream";
import { whenAborted } from "../../internal/signal.js";

/**
 * Pulls exact byte counts off a socket. A frame is a header then a length then
 * a payload, and the socket hands over whatever arrived, so something has to
 * hold the remainder between reads — including the bytes that came in behind
 * the handshake response, which are the first frames.
 */
export class SocketReader {
  #buffered: Buffer = Buffer.alloc(0);
  #failure: Error | null = null;
  #wake: (() => void) | null = null;

  constructor(socket: Duplex) {
    socket.on("data", (chunk: Buffer) => {
      this.#buffered = this.#buffered.length === 0 ? chunk : Buffer.concat([this.#buffered, chunk]);
      this.#wake?.();
    });
    socket.on("error", (error: Error) => this.#fail(error));
    socket.on("end", () => this.#fail(new Error("actioncable: the server hung up")));
    socket.on("close", () => this.#fail(new Error("actioncable: the connection is closed")));
  }

  /** Reads exactly `length` bytes, waiting for them to arrive. */
  async readExactly(length: number, signal?: AbortSignal): Promise<Buffer> {
    await this.#until(() => this.#buffered.length >= length, signal);

    return this.#take(length);
  }

  /** Reads up to and including `delimiter`, for the handshake's response head. */
  async readUntil(delimiter: string, limit: number, signal?: AbortSignal): Promise<Buffer> {
    const marker = Buffer.from(delimiter, "latin1");
    let end = -1;

    await this.#until(() => {
      end = this.#buffered.indexOf(marker);
      if (end === -1 && this.#buffered.length > limit) {
        throw new Error(`actioncable: the server's response head is longer than ${limit} bytes`);
      }
      return end !== -1;
    }, signal);

    return this.#take(end + marker.length);
  }

  #take(length: number): Buffer {
    const taken = this.#buffered.subarray(0, length);
    this.#buffered = this.#buffered.subarray(length);

    return taken;
  }

  async #until(enough: () => boolean, signal: AbortSignal | undefined): Promise<void> {
    for (;;) {
      if (enough()) {
        return;
      }
      if (this.#failure !== null) {
        throw this.#failure;
      }
      signal?.throwIfAborted();

      await this.#more(signal);
    }
  }

  #more(signal: AbortSignal | undefined): Promise<void> {
    const { aborted, cancel } = whenAborted(signal);

    return new Promise<void>((resolve) => {
      this.#wake = resolve;
      void aborted.then(resolve);
    }).finally(() => {
      this.#wake = null;
      cancel();
    });
  }

  #fail(error: Error): void {
    this.#failure ??= error;
    this.#wake?.();
  }
}
