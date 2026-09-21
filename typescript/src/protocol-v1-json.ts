import { Message } from "./message.js";
import type { Command, Incoming, IncomingKind, Protocol } from "./protocol.js";

/** The subprotocol every Rails Action Cable server speaks. */
export const SUBPROTOCOL_V1_JSON = "actioncable-v1-json";

/**
 * The `actioncable-v1-json` protocol: JSON objects in text frames, keyed by
 * command going out and by type coming in.
 */
export class V1JSON implements Protocol {
  readonly subprotocol = SUBPROTOCOL_V1_JSON;

  encode(command: Command): string {
    if (command.data === undefined || command.data === "") {
      return JSON.stringify({ command: command.name, identifier: command.identifier });
    } else {
      return JSON.stringify({
        command: command.name,
        identifier: command.identifier,
        data: command.data,
      });
    }
  }

  decode(payload: string): Incoming {
    const frame = parse(payload);

    return {
      kind: kindOf(frame.type),
      identifier: typeof frame.identifier === "string" ? frame.identifier : "",
      message: new Message(frame.message === undefined ? "" : JSON.stringify(frame.message)),
      reason: typeof frame.reason === "string" ? frame.reason : "",
      reconnect: frame.reconnect === true,
    };
  }
}

interface V1JSONFrame {
  type?: unknown;
  identifier?: unknown;
  message?: unknown;
  reason?: unknown;
  reconnect?: unknown;
}

function parse(payload: string): V1JSONFrame {
  let frame: unknown;
  try {
    frame = JSON.parse(payload);
  } catch (cause) {
    throw new SyntaxError(`actioncable: decoding ${truncate(payload, 200)}`, { cause });
  }

  if (frame === null || typeof frame !== "object" || Array.isArray(frame)) {
    throw new SyntaxError(`actioncable: decoding ${truncate(payload, 200)}: not a JSON object`);
  }

  return frame as V1JSONFrame;
}

/**
 * Anything without a recognized type is a channel message, which is how the
 * server sends them: an identifier and a message, and no type at all.
 */
function kindOf(type: unknown): IncomingKind {
  switch (type) {
    case "welcome":
      return "welcome";
    case "ping":
      return "ping";
    case "disconnect":
      return "disconnect";
    case "confirm_subscription":
      return "confirmation";
    case "reject_subscription":
      return "rejection";
    default:
      return "message";
  }
}

function truncate(payload: string, limit: number): string {
  if (payload.length > limit) {
    return `${payload.slice(0, limit)}…`;
  } else {
    return payload;
  }
}
