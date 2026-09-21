/**
 * The undecoded payload a channel broadcast or transmitted. Its shape is
 * entirely up to the channel, so `json()` it into the expected type.
 *
 * Go keeps the server's bytes verbatim in a `json.RawMessage`. Here `raw` is
 * the payload re-encoded from the frame the protocol decoded, so the text is
 * canonical JSON rather than byte-for-byte what arrived — the value is the
 * same, the whitespace may not be.
 */
export class Message {
  constructor(readonly raw: string) {}

  /** Decodes the payload. */
  json<T = unknown>(): T {
    return JSON.parse(this.raw) as T;
  }

  toString(): string {
    return this.raw;
  }

  toJSON(): unknown {
    return this.json();
  }
}
