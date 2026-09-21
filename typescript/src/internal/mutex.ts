/**
 * Serializes async sections. One `await` inside a critical section is enough
 * for another caller to run through it, so the client's writes need a lock
 * even on a single thread: a resubscribe that is mid-list must finish its list
 * before an unsubscribe for the same identifier gets a frame out.
 */
export class Mutex {
  #tail: Promise<void> = Promise.resolve();

  /** Waits for the lock and answers with the release. */
  async lock(): Promise<() => void> {
    let release!: () => void;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });

    const ours = this.#tail;
    this.#tail = ours.then(() => held);
    await ours;

    return release;
  }

  /** Runs `work` with the lock held. */
  async locked<T>(work: () => Promise<T> | T): Promise<T> {
    const release = await this.lock();
    try {
      return await work();
    } finally {
      release();
    }
  }
}
