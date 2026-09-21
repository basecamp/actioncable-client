/**
 * A client for Rails' Action Cable.
 *
 * A {@link Client} owns one WebSocket connection to an Action Cable server and
 * multiplexes any number of channel subscriptions over it. It keeps the
 * connection alive the way the official JavaScript client does: the server
 * beats a ping every three seconds, and a connection that goes quiet for
 * longer than `staleAfter` is torn down and redialed with backoff.
 * Subscriptions survive reconnects — they are resubscribed as soon as the
 * server says welcome.
 *
 * ```ts
 * import { Client } from "@37signals/actioncable";
 *
 * const client = new Client("wss://example.com/cable");
 * await client.connect();
 *
 * const room = await client.subscribe({ channel: "RoomChannel", params: { id: 42 } });
 * await room.perform("speak", { body: "Hello!" });
 *
 * for await (const message of room) {
 *   console.log(message.json<{ body: string }>().body);
 * }
 * ```
 *
 * Two things are pluggable. A {@link Transport} carries bytes —
 * {@link WebSocketTransport} wraps the platform's own `WebSocket`,
 * `NodeTransport` speaks RFC 6455 on `node:net`, and any WebSocket package can
 * be dropped in behind the same interface. A {@link Protocol} speaks one
 * Action Cable wire format, negotiated as one WebSocket subprotocol —
 * {@link V1JSON} implements `actioncable-v1-json`, and a new format is a new
 * `Protocol` rather than a fork of this client.
 *
 * This is the entry point every runtime but Node resolves, and its default
 * transport is `WebSocketTransport`. Under Node, `@37signals/actioncable`
 * resolves the `node` condition instead and defaults to `NodeTransport`,
 * which is the only one that can send headers.
 */
export { Client } from "./client.js";
export { Subscription, type SubscriptionHost } from "./subscription.js";
export { Message } from "./message.js";
export { identifierKey, type Identifier, type Params } from "./identifier.js";
export { silentLogger, type Logger } from "./logger.js";
export { VERSION } from "./version.js";

export {
  DEFAULTS,
  type Backoff,
  type ClientOptions,
  type SendOptions,
  type SubscribeOptions,
} from "./options.js";

export {
  SUBPROTOCOL_UNSUPPORTED,
  type Command,
  type CommandName,
  type Incoming,
  type IncomingKind,
  type Protocol,
} from "./protocol.js";
export { SUBPROTOCOL_V1_JSON, V1JSON } from "./protocol-v1-json.js";

export {
  isStatusCloser,
  type Connection,
  type DialOptions,
  type HeaderEntries,
  type HeaderInit,
  type StatusCloser,
  type TransferOptions,
  type Transport,
} from "./transport.js";
export { WebSocketTransport, type WebSocketLike } from "./transport/websocket.js";
export { defaultTransport, useDefaultTransport } from "./default-transport.js";

export {
  AbortedError,
  ActionCableError,
  AlreadyConnectedError,
  ClosedError,
  CloseError,
  DisconnectError,
  DisconnectReason,
  GaveUpError,
  HandshakeError,
  MessageTooBigError,
  NoProtocolsError,
  NotConnectedError,
  ProtocolViolationError,
  RejectedError,
  StaleConnectionError,
  UnsubscribedError,
  UnsupportedSubprotocolError,
} from "./errors.js";
