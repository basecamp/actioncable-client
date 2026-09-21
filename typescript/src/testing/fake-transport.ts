import { Deferred } from "../internal/deferred.js";
import { whenAborted } from "../internal/signal.js";
import type { Connection, DialOptions, Transport, TransferOptions } from "../transport.js";

/** How long a fake waits for something that should already have happened. */
const WAIT = 2_000;

/** How long "nothing happened" takes to establish. */
const QUIET = 100;

/**
 * Hands out in-memory connections a test plays the server on. It is what this
 * package's own tests drive the client over, and it is exported because a
 * client's users need the same thing: a cable server, in the test process,
 * that says exactly what the test wants said.
 *
 * ```ts
 * const transport = new FakeTransport();
 * const client = new Client("ws://example.com/cable", { transport });
 *
 * const connecting = client.connect();
 * const connection = await transport.accept();
 * await connection.welcome();
 * await connecting;
 * ```
 */
export class FakeTransport implements Transport {
  /** What the server says it negotiated. */
  subprotocol = "actioncable-v1-json";

  /**
   * How many commands a connection takes before a write waits on the test
   * reading them. Zero makes every write wait, which lets a test hold the
   * client mid-write.
   */
  writeBuffer = 32;

  readonly #dialed: FakeConnection[] = [];
  readonly #dials = new Notifier();
  readonly #dialErrors: unknown[] = [];
  #options: DialOptions = {};

  dial(_url: string, options: DialOptions): Promise<Connection> {
    this.#options = options;

    if (this.#dialErrors.length > 0) {
      return Promise.reject(this.#dialErrors.shift());
    }

    const connection = new FakeConnection(this.subprotocol, this.writeBuffer);
    this.#dialed.push(connection);
    this.#dials.notify();

    return Promise.resolve(connection);
  }

  /** The options the client last dialed with. */
  get dialedWith(): DialOptions {
    return this.#options;
  }

  /** One header the client last dialed with. */
  header(name: string): string | null {
    const entries: Array<[string, string]> = [...(this.#options.headers ?? [])];

    return new Headers(entries).get(name);
  }

  /** The subprotocols the client last offered. */
  get offered(): string[] {
    return this.#options.subprotocols ?? [];
  }

  /** Turns the next dial down with this error. */
  failNextDial(error: unknown): void {
    this.#dialErrors.push(error);
  }

  /** Waits for the client to dial, and answers with the connection. */
  async accept(): Promise<FakeConnection> {
    const dialed = await this.#nextDial(WAIT);
    if (dialed === undefined) {
      throw new Error("actioncable: no connection was dialed");
    }

    return dialed;
  }

  /** Fails when the client dials in the next little while. */
  async expectNoDial(within = QUIET * 2): Promise<void> {
    const dialed = await this.#nextDial(within);
    if (dialed !== undefined) {
      throw new Error(
        `actioncable: expected no connection, got one with subprotocol ${dialed.subprotocol}`,
      );
    }
  }

  async #nextDial(within: number): Promise<FakeConnection | undefined> {
    const deadline = Date.now() + within;

    for (;;) {
      const dialed = this.#dialed.shift();
      if (dialed !== undefined) {
        return dialed;
      }

      const left = deadline - Date.now();
      if (left <= 0) {
        return undefined;
      }

      await Promise.race([this.#dials.waited(), sleep(left)]);
    }
  }
}

/** One command the client sent, as the server would read it. */
export interface FakeCommand {
  command: string;
  identifier: string;
  data?: string;
}

/**
 * One connection with the test playing the server on the other end. Like
 * Rails it keeps one subscription per identifier: a subscribe for an
 * identifier it has already heard, answered or not, is ignored.
 */
export class FakeConnection implements Connection {
  readonly subprotocol: string;

  readonly #writeBuffer: number;
  readonly #closed = new Deferred();

  /** Written and not yet read, up to `writeBuffer` of them. */
  readonly #sent: string[] = [];
  /** A write with nowhere to go until the test reads: an unbuffered send. */
  readonly #blocked: Array<{ payload: string; taken: Deferred }> = [];
  readonly #written = new Notifier();

  /** The client's outstanding `read`, if it has one. */
  #reading: ((payload: string) => void) | null = null;
  readonly #reads = new Notifier();

  readonly #subscribed = new Set<string>();
  #writingStarted = new Deferred();

  constructor(subprotocol: string, writeBuffer: number) {
    this.subprotocol = subprotocol;
    this.#writeBuffer = writeBuffer;
  }

  // The Connection the client talks over.

  async read(options: TransferOptions = {}): Promise<string> {
    const { aborted, cancel } = whenAborted(options.signal);
    try {
      const payload = await new Promise<string | null>((resolve) => {
        this.#reading = resolve;
        this.#reads.notify();
        void this.#closed.promise.then(() => resolve(null));
        void aborted.then(() => resolve(null));
      });

      if (payload === null) {
        options.signal?.throwIfAborted();
        throw new Error("actioncable: the fake connection is closed");
      }

      return payload;
    } finally {
      this.#reading = null;
      cancel();
    }
  }

  async write(payload: string, options: TransferOptions = {}): Promise<void> {
    if (this.#ignores(payload)) {
      return;
    }

    this.#writingStarted.resolve();

    if (this.#sent.length < this.#writeBuffer) {
      this.#sent.push(payload);
      this.#written.notify();
      return;
    }

    const taken = new Deferred();
    this.#blocked.push({ payload, taken });
    this.#written.notify();

    const { aborted, cancel } = whenAborted(options.signal);
    try {
      await Promise.race([taken.promise, this.#closed.promise, aborted]);
    } finally {
      cancel();
    }

    if (!taken.settled) {
      const waiting = this.#blocked.findIndex((entry) => entry.taken === taken);
      if (waiting !== -1) {
        this.#blocked.splice(waiting, 1);
      }
      options.signal?.throwIfAborted();
      throw new Error("actioncable: the fake connection is closed");
    }
  }

  close(): Promise<void> {
    this.#closed.resolve();

    return Promise.resolve();
  }

  // What the test says and hears.

  /** Resolves once the client has started a write nobody has read yet. */
  get writing(): Promise<void> {
    return this.#writingStarted.promise;
  }

  /** Plays a server frame to the client. */
  async push(frame: string): Promise<void> {
    const deadline = Date.now() + WAIT;

    for (;;) {
      const reading = this.#reading;
      if (reading !== null) {
        this.#reading = null;
        reading(frame);
        return;
      }
      if (this.#closed.settled) {
        throw new Error(`actioncable: connection closed before ${frame} could be sent`);
      }

      const left = deadline - Date.now();
      if (left <= 0) {
        throw new Error(`actioncable: client never read ${frame}`);
      }

      await Promise.race([this.#reads.waited(), sleep(left)]);
    }
  }

  welcome(): Promise<void> {
    return this.push(`{"type":"welcome"}`);
  }

  ping(at = 1755400000): Promise<void> {
    return this.push(`{"type":"ping","message":${at}}`);
  }

  confirm(identifier: string): Promise<void> {
    return this.push(`{"type":"confirm_subscription","identifier":${quote(identifier)}}`);
  }

  /**
   * Turns a subscription down, which also forgets it: the client is free to
   * try again.
   */
  reject(identifier: string): Promise<void> {
    this.#subscribed.delete(identifier);

    return this.push(`{"type":"reject_subscription","identifier":${quote(identifier)}}`);
  }

  disconnect(reason: string, reconnect: boolean): Promise<void> {
    return this.push(
      `{"type":"disconnect","reason":${quote(reason)},"reconnect":${String(reconnect)}}`,
    );
  }

  broadcast(identifier: string, message: unknown): Promise<void> {
    return this.push(`{"identifier":${quote(identifier)},"message":${JSON.stringify(message)}}`);
  }

  /** The next payload the client writes, exactly as it went out. */
  async sent(): Promise<string> {
    const deadline = Date.now() + WAIT;

    for (;;) {
      const payload = this.#take();
      if (payload !== undefined) {
        return payload;
      }

      const left = deadline - Date.now();
      if (left <= 0) {
        throw new Error("actioncable: client sent nothing");
      }

      await Promise.race([this.#written.waited(), sleep(left)]);
    }
  }

  /**
   * The next command the client sends. Nobody has heard it yet: `command` and
   * `dropCommand` settle that.
   */
  async next(): Promise<FakeCommand> {
    return JSON.parse(await this.sent()) as FakeCommand;
  }

  /** The next command the client sends, taken in the way the server would. */
  async command(): Promise<FakeCommand> {
    const command = await this.next();
    this.#hear(command);

    return command;
  }

  /**
   * Lets the next command fall on the floor, the way the server drops a
   * subscribe that reaches it before the connection is set up.
   */
  dropCommand(): Promise<FakeCommand> {
    return this.next();
  }

  /** Fails when the client sends anything in the next little while. */
  async expectNoCommand(within = QUIET): Promise<void> {
    const deadline = Date.now() + within;

    for (;;) {
      const waiting = this.#sent[0] ?? this.#blocked[0]?.payload;
      if (waiting !== undefined) {
        throw new Error(`actioncable: expected no command, got ${waiting}`);
      }

      const left = deadline - Date.now();
      if (left <= 0) {
        return;
      }

      await Promise.race([this.#written.waited(), sleep(Math.min(left, 10))]);
    }
  }

  #take(): string | undefined {
    const payload = this.#sent.shift();
    if (payload !== undefined) {
      this.#release();
      return payload;
    }

    const blocked = this.#blocked.shift();
    if (blocked !== undefined) {
      blocked.taken.resolve();
      return blocked.payload;
    }

    return undefined;
  }

  /** Lets one blocked write into the buffer the read just made room in. */
  #release(): void {
    const blocked = this.#blocked.shift();
    if (blocked !== undefined) {
      this.#sent.push(blocked.payload);
      blocked.taken.resolve();
    }
  }

  #hear(command: FakeCommand): void {
    if (command.command === "subscribe") {
      this.#subscribed.add(command.identifier);
    } else if (command.command === "unsubscribe") {
      this.#subscribed.delete(command.identifier);
    }
  }

  /**
   * Whether the server would drop the command without a word: Rails does that
   * to a second subscribe for an identifier the connection already has.
   */
  #ignores(payload: string): boolean {
    let command: FakeCommand;
    try {
      command = JSON.parse(payload) as FakeCommand;
    } catch {
      return false;
    }

    return command.command === "subscribe" && this.#subscribed.has(command.identifier);
  }
}

/** Wakes everyone waiting on it, without holding a value. */
class Notifier {
  #waiting: Array<() => void> = [];

  notify(): void {
    const waiting = this.#waiting;
    this.#waiting = [];
    for (const wake of waiting) {
      wake();
    }
  }

  waited(): Promise<void> {
    return new Promise((resolve) => {
      this.#waiting.push(resolve);
    });
  }
}

function quote(value: string): string {
  return JSON.stringify(value);
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}
