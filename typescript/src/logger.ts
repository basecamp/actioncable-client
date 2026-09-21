/**
 * Takes the client's chatter — dropped messages, failed connections, retries.
 * `console` satisfies it, and so does anything else with a `log`.
 */
export interface Logger {
  log(message: string): void;
}

/** Swallows everything. What a client without a logger uses. */
export const silentLogger: Logger = { log() {} };
