import type { Transport } from "./transport.js";
import { WebSocketTransport } from "./transport/websocket.js";

/**
 * What a client built without a `transport` uses.
 *
 * The platform's own `WebSocket` is the one every runtime has, so it is the
 * floor. The `@37signals/actioncable` entry point Node resolves raises that
 * floor to `NodeTransport` — the only one that can send headers — by calling
 * `useDefaultTransport` as it loads, which happens before any client can be
 * built. A browser bundle resolves the other entry point and never pulls
 * `node:net` in.
 */
let build: () => Transport = () => new WebSocketTransport();

export function defaultTransport(): Transport {
  return build();
}

/** Sets what a client without an explicit transport gets. */
export function useDefaultTransport(factory: () => Transport): void {
  build = factory;
}
