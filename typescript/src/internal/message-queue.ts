import { whenAborted } from "./signal.js";

/**
 * An unbounded queue of payloads with one reader. A transport that is handed
 * frames by callbacks — the platform `WebSocket` is one — parks them here
 * until `read` asks, and `fail` turns every later read into the error that
 * ended the connection.
 */
export class MessageQueue {
  #queue: string[] = [];
  #waiting: ((payload: string) => void) | null = null;
  #failWaiting: ((error: Error) => void) | null = null;
  #failure: Error | null = null;

  push(payload: string): void {
    if (this.#failure !== null) {
      return;
    }

    const waiting = this.#waiting;
    if (waiting !== null) {
      this.#waiting = null;
      this.#failWaiting = null;
      waiting(payload);
    } else {
      this.#queue.push(payload);
    }
  }

  /** Ends the queue. What is already in it is still read, then the error. */
  fail(error: Error): void {
    this.#failure ??= error;

    const failWaiting = this.#failWaiting;
    if (failWaiting !== null) {
      this.#waiting = null;
      this.#failWaiting = null;
      failWaiting(this.#failure);
    }
  }

  async next(signal?: AbortSignal): Promise<string> {
    const queued = this.#queue.shift();
    if (queued !== undefined) {
      return queued;
    }
    if (this.#failure !== null) {
      throw this.#failure;
    }

    signal?.throwIfAborted();

    const { aborted, cancel } = whenAborted(signal);
    try {
      return await new Promise<string>((resolve, reject) => {
        this.#waiting = resolve;
        this.#failWaiting = reject;
        void aborted.then(() => {
          if (this.#waiting === resolve) {
            this.#waiting = null;
            this.#failWaiting = null;
            reject(asError(signal?.reason));
          }
        });
      });
    } finally {
      cancel();
    }
  }
}

function asError(reason: unknown): Error {
  if (reason instanceof Error) {
    return reason;
  } else {
    return new Error(String(reason));
  }
}
