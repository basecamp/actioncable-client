import type { Logger } from "../logger.js";

export type Callback = () => void | Promise<void>;

/**
 * Runs a subscription's callbacks off the caller's flow, one at a time, in the
 * order the events happened.
 *
 * Callbacks belong off the connection's flow: an `onDisconnected` calling
 * `close` or an `onConnected` calling `subscribe` are both reasonable things
 * to write, and both wait on work the connection is in the middle of. The
 * queue is unbounded for the same reason — handing an event over must never
 * block the connection.
 *
 * An async callback is awaited, so "the callback has returned" means its
 * promise settled. Once stopped the dispatcher runs what it still holds, turns
 * away anything handed to it after that, then calls `afterStop`. That is how a
 * subscription ends its messages only after its last callback has returned,
 * with none left behind unrun.
 */
export class Dispatcher {
  #pending: Callback[] = [];
  #running = false;
  #stopping = false;
  #finished = false;
  readonly #afterStop: () => void;
  readonly #logger: Logger;

  constructor(afterStop: () => void, logger: Logger) {
    this.#afterStop = afterStop;
    this.#logger = logger;
  }

  dispatch(callback: Callback | undefined): void {
    if (callback === undefined || this.#stopping) {
      return;
    }

    this.#pending.push(callback);
    this.#wake();
  }

  /**
   * Lets the dispatcher finish what it has and go away. It doesn't wait, since
   * a callback is allowed to be what stopped it.
   */
  stop(): void {
    if (!this.#stopping) {
      this.#stopping = true;
      this.#wake();
    }
  }

  #wake(): void {
    if (!this.#running && !this.#finished) {
      this.#running = true;
      queueMicrotask(() => void this.#drain());
    }
  }

  async #drain(): Promise<void> {
    try {
      for (;;) {
        const callback = this.#pending.shift();
        if (callback === undefined) {
          break;
        }

        try {
          await callback();
        } catch (error) {
          this.#logger.log(`actioncable: a subscription callback threw: ${describe(error)}`);
        }
      }
    } finally {
      this.#running = false;
    }

    if (this.#stopping && this.#pending.length === 0 && !this.#finished) {
      this.#finished = true;
      this.#afterStop();
    } else if (this.#pending.length > 0) {
      this.#wake();
    }
  }
}

function describe(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  } else {
    return String(error);
  }
}
