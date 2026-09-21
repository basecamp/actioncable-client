/**
 * The entry point Node resolves for `@37signals/actioncable`, and the one to
 * import by name — `@37signals/actioncable/node` — where the runtime is Node
 * but the resolver's conditions say otherwise.
 *
 * It is the same package as the default entry point with one difference: a
 * client built without a transport gets `NodeTransport`, which speaks RFC 6455
 * on `node:net` and sends the headers it is handed. The platform's own
 * `WebSocket` cannot send headers, and an Action Cable server authorizes the
 * upgrade request, so a cookie or a bearer token needs this one.
 *
 * A browser bundle resolves `./index.js` instead and never pulls `node:net`
 * in.
 */
import { useDefaultTransport } from "./default-transport.js";
import { NodeTransport } from "./transport/node.js";

useDefaultTransport(() => new NodeTransport());

export * from "./index.js";
export { NodeTransport, type NodeTransportOptions } from "./transport/node.js";
