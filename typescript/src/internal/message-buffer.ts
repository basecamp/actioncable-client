import type { Message } from "../message.js";

/**
 * A subscription's messages, buffered. Go uses a buffered channel: a send that
 * would block is dropped rather than stalling the connection, and closing the
 * channel ends the reader's loop. This is the same thing an async iterator can
 * read.
 */
export class MessageBuffer {
  #queue: Message[] = [];
  #waiting: ((result: IteratorResult<Message>) => void) | null = null;
  #ended = false;

  constructor(readonly capacity: number) {}

  /** Takes a message, or answers false when the buffer is full. */
  push(message: Message): boolean {
    if (this.#ended) {
      return true;
    }

    if (this.#waiting !== null) {
      const waiting = this.#waiting;
      this.#waiting = null;
      waiting({ done: false, value: message });
      return true;
    }

    if (this.#queue.length >= this.capacity) {
      return false;
    }

    this.#queue.push(message);

    return true;
  }

  /** Ends the iteration once what is already buffered has been read. */
  end(): void {
    if (this.#ended) {
      return;
    }

    this.#ended = true;
    if (this.#waiting !== null) {
      const waiting = this.#waiting;
      this.#waiting = null;
      waiting({ done: true, value: undefined });
    }
  }

  next(): Promise<IteratorResult<Message>> {
    const message = this.#queue.shift();
    if (message !== undefined) {
      return Promise.resolve({ done: false, value: message });
    }

    if (this.#ended) {
      return Promise.resolve({ done: true, value: undefined });
    }

    return new Promise((resolve) => {
      this.#waiting = resolve;
    });
  }
}
