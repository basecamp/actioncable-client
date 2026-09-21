/**
 * A promise somebody else settles. Go closes a channel to say something has
 * happened once and for all — a welcome, a confirmation, a client that has
 * stopped — and this is the same thing: resolve once, and every waiter, before
 * or after, goes on.
 */
export class Deferred<T = void> {
  #resolve!: (value: T) => void;
  #settled = false;

  readonly promise: Promise<T>;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.#resolve = resolve;
    });
  }

  get settled(): boolean {
    return this.#settled;
  }

  resolve(value: T): void {
    if (!this.#settled) {
      this.#settled = true;
      this.#resolve(value);
    }
  }
}
