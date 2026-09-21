/**
 * A promise that resolves when the signal aborts, and a `cancel` that takes
 * the listener off again. `Promise.race` over a signal that never aborts
 * would otherwise keep a listener on it for as long as the signal lives.
 */
export function whenAborted(signal: AbortSignal | undefined): {
  aborted: Promise<void>;
  cancel: () => void;
} {
  if (signal === undefined) {
    return { aborted: new Promise<void>(() => {}), cancel: () => {} };
  }

  const controller = new AbortController();
  const aborted = new Promise<void>((resolve) => {
    if (signal.aborted) {
      resolve();
    } else {
      signal.addEventListener("abort", () => resolve(), {
        once: true,
        signal: controller.signal,
      });
    }
  });

  return { aborted, cancel: () => controller.abort() };
}

/** Sleeps, and wakes early when the signal aborts. */
export function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }

    const timer = setTimeout(() => {
      signal.removeEventListener("abort", wake);
      resolve();
    }, milliseconds);

    function wake(): void {
      clearTimeout(timer);
      resolve();
    }

    signal.addEventListener("abort", wake, { once: true });
  });
}
