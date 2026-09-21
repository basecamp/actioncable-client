import type { Message } from "./message.js";

/**
 * Translates between Action Cable commands and the text on the wire. It is the
 * seam where an Action Cable protocol plugs in.
 *
 * One protocol speaks one subprotocol. A client offers every protocol it was
 * given and speaks the one the server picks, so supporting a new protocol
 * means adding one rather than replacing the list.
 */
export interface Protocol {
  /** The name this protocol negotiates under. */
  readonly subprotocol: string;

  /** Turns a command into one outgoing message. */
  encode(command: Command): string;

  /** Turns one incoming message into a frame the client understands. */
  decode(payload: string): Incoming;
}

/**
 * The sentinel an Action Cable server names when it speaks none of the
 * subprotocols offered. The client offers it last on every handshake, the way
 * Rails' own clients do, so a server with nothing in common can say so
 * outright instead of leaving the subprotocol blank.
 */
export const SUBPROTOCOL_UNSUPPORTED = "actioncable-unsupported";

/** The verb of a client-to-server command. */
export type CommandName = "subscribe" | "unsubscribe" | "message";

/**
 * A client-to-server message. `data` carries the already encoded action
 * payload and is only set for a `message` command.
 */
export interface Command {
  name: CommandName;
  identifier: string;
  data?: string;
}

/** The type of a server-to-client frame. */
export type IncomingKind =
  "welcome" | "ping" | "disconnect" | "confirmation" | "rejection" | "message";

/**
 * A decoded server-to-client frame. `reason` and `reconnect` only say anything
 * on a disconnect, `message` on a message and a ping; the rest of the time
 * they are empty rather than absent, so a protocol has one shape to fill in.
 */
export interface Incoming {
  kind: IncomingKind;
  identifier: string;
  message: Message;
  reason: string;
  reconnect: boolean;
}
