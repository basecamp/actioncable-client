/**
 * Every error this package raises. Go names these as sentinel values compared
 * with `errors.Is`; the equivalent here is a class hierarchy compared with
 * `instanceof`, and a wrapped failure hangs off `cause` the way Go's `%w`
 * wraps one.
 */
export class ActionCableError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = new.target.name;
  }
}

/**
 * The client has been closed, or stopped because the server told it not to
 * reconnect.
 */
export class ClosedError extends ActionCableError {
  constructor() {
    super("actioncable: client closed");
  }
}

/**
 * A command could not be sent because the connection is down. Subscriptions
 * recover on their own; a `perform` or `send` that hits this is lost and must
 * be retried.
 */
export class NotConnectedError extends ActionCableError {
  constructor() {
    super("actioncable: not connected");
  }
}

/** The channel's `subscribed` method turned the subscription down. */
export class RejectedError extends ActionCableError {
  constructor(readonly identifier: string) {
    super(`actioncable: subscription rejected: ${identifier}`);
  }
}

/**
 * The server negotiated a subprotocol none of the client's protocols speak.
 * Reconnecting won't fix that, so the client stops.
 */
export class UnsupportedSubprotocolError extends ActionCableError {
  constructor(
    readonly subprotocol: string,
    readonly offered: string[],
  ) {
    super(
      subprotocol === "actioncable-unsupported"
        ? `actioncable: unsupported subprotocol: the server speaks none of ${offered.join(", ")}`
        : `actioncable: unsupported subprotocol: ${JSON.stringify(subprotocol)}`,
    );
  }
}

/** `connect` was called on a client that is already running. */
export class AlreadyConnectedError extends ActionCableError {
  constructor() {
    super("actioncable: already connected");
  }
}

/** There is nothing to offer the server: `protocols` was given but empty. */
export class NoProtocolsError extends ActionCableError {
  constructor() {
    super("actioncable: no protocols to offer");
  }
}

/**
 * As many attempts failed in a row as `maxAttempts` allows. `cause` is the last
 * attempt's error.
 */
export class GaveUpError extends ActionCableError {
  constructor(readonly lastAttempt?: unknown) {
    super(`actioncable: gave up connecting${describeAttempt(lastAttempt)}`, {
      cause: lastAttempt,
    });
  }
}

/**
 * A `connect` whose signal was aborted before the welcome arrived. `name` is
 * the aborting reason's own — `AbortError` for a cancellation, `TimeoutError`
 * for an `AbortSignal.timeout` — so the usual web check on `error.name` works,
 * `cause` is the reason itself, and the message names what the client was
 * waiting out.
 */
export class AbortedError extends ActionCableError {
  constructor(
    reason: unknown,
    readonly lastAttempt?: unknown,
  ) {
    super(`actioncable: ${describeReason(reason)}${describeAttempt(lastAttempt)}`, {
      cause: reason,
    });
    this.name = nameOf(reason) ?? this.name;
  }
}

/**
 * The connection went quiet for longer than `staleAfter`. Rails beats a ping
 * every three seconds, so silence means the socket is dead even though nothing
 * said so.
 */
export class StaleConnectionError extends ActionCableError {
  constructor(
    readonly staleAfter: number,
    options?: ErrorOptions,
  ) {
    super(`actioncable: no frame in ${staleAfter}ms`, options);
  }
}

/** A subscription's `error` after `unsubscribe`. */
export class UnsubscribedError extends ActionCableError {
  constructor() {
    super("actioncable: unsubscribed");
  }
}

/**
 * The server sent a message larger than the transport allows. It is refused as
 * soon as its length is known, before any of it is read in, and the connection
 * is failed.
 */
export class MessageTooBigError extends ActionCableError {
  constructor(message: string) {
    super(`actioncable: message exceeds the maximum size: ${message}`);
  }
}

/** Disconnect reasons an Action Cable server sends before hanging up. */
export const DisconnectReason = {
  unauthorized: "unauthorized",
  invalidRequest: "invalid_request",
  serverRestart: "server_restart",
  remote: "remote",
} as const;

export type DisconnectReason = (typeof DisconnectReason)[keyof typeof DisconnectReason];

/** The server sent a disconnect frame. */
export class DisconnectError extends ActionCableError {
  constructor(
    readonly reason: string,
    readonly reconnect: boolean,
  ) {
    super(`actioncable: server disconnected: ${reason}`);
  }
}

/**
 * The server answered the upgrade request with something other than 101
 * Switching Protocols. `statusCode` is what it answered instead, so a caller
 * can tell a redirect from a refusal; `status` is the whole status line as the
 * server wrote it.
 */
export class HandshakeError extends ActionCableError {
  constructor(
    readonly statusCode: number,
    readonly status: string,
  ) {
    super(`actioncable: server refused the upgrade with ${status}`);
  }
}

/**
 * The server closed the connection with a close frame. `code` is the status
 * code it carried, 1005 when it carried none, and `reason` the text after it.
 */
export class CloseError extends ActionCableError {
  constructor(
    readonly code: number,
    readonly reason: string = "",
  ) {
    super(
      reason === ""
        ? `actioncable: server closed the connection: ${code}`
        : `actioncable: server closed the connection: ${code} ${reason}`,
    );
  }
}

/** The peer isn't speaking RFC 6455, so reading on would be guesswork. */
export class ProtocolViolationError extends ActionCableError {
  constructor(what: string) {
    super(`actioncable: ${what}`);
  }
}

function describeAttempt(lastAttempt: unknown): string {
  if (lastAttempt === undefined) {
    return "";
  } else {
    return ` (last attempt: ${messageOf(lastAttempt)})`;
  }
}

function describeReason(reason: unknown): string {
  if (nameOf(reason) === "TimeoutError") {
    return "connecting timed out";
  } else {
    return "connecting was aborted";
  }
}

function nameOf(reason: unknown): string | undefined {
  if (reason instanceof Error) {
    return reason.name;
  } else {
    return undefined;
  }
}

function messageOf(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  } else {
    return String(error);
  }
}
