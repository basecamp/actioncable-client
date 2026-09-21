import { createHash, randomBytes } from "node:crypto";
import { HandshakeError } from "../../errors.js";
import type { HeaderEntries } from "../../transport.js";

const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** What this client calls itself when the caller hasn't said otherwise. */
export const USER_AGENT = "actioncable-js";

export interface UpgradeRequest {
  endpoint: URL;
  key: string;
  subprotocols: string[];
  headers: HeaderEntries;
}

export interface UpgradeResponse {
  statusCode: number;
  status: string;
  headers: Map<string, string>;
}

export function nonce(): string {
  return randomBytes(16).toString("base64");
}

export function acceptKey(key: string): string {
  return createHash("sha1")
    .update(key + WEBSOCKET_GUID)
    .digest("base64");
}

/**
 * The opening request, byte for byte. It is written by hand rather than
 * through `node:http` because the socket has to stay ours the moment the
 * server answers 101, and because nothing ambient — no proxy, no cookie jar,
 * no keep-alive — gets to add to what the caller asked for.
 */
export function upgradeRequest(request: UpgradeRequest): Buffer {
  const { endpoint, key, subprotocols } = request;
  const path = `${endpoint.pathname}${endpoint.search}`;

  const headers = new HeaderList(request.headers);
  headers.delete("Sec-WebSocket-Extensions");
  headers.fillIn("User-Agent", USER_AGENT);
  headers.set("Upgrade", "websocket");
  headers.set("Connection", "Upgrade");
  headers.set("Sec-WebSocket-Key", key);
  headers.set("Sec-WebSocket-Version", "13");
  if (subprotocols.length > 0) {
    headers.set("Sec-WebSocket-Protocol", subprotocols.join(", "));
  } else {
    headers.delete("Sec-WebSocket-Protocol");
  }

  const lines = [
    `GET ${path === "" ? "/" : path} HTTP/1.1`,
    `Host: ${endpoint.host}`,
    ...headers.lines(),
  ];

  return Buffer.from(`${lines.join("\r\n")}\r\n\r\n`, "latin1");
}

/**
 * The request's headers while they are being assembled. A `Headers` would do
 * most of this, but it also lowercases every name it is given and refuses a
 * value outright where the wire wants one neutralized, so the list the
 * request is written from is kept here instead.
 */
class HeaderList {
  readonly #entries = new Map<string, { name: string; value: string }>();

  constructor(headers: HeaderEntries | undefined) {
    for (const [name, value] of headers ?? []) {
      this.set(name, value);
    }
  }

  set(name: string, value: string): void {
    this.#entries.set(name.toLowerCase(), { name, value });
  }

  fillIn(name: string, value: string): void {
    if (!this.#entries.has(name.toLowerCase())) {
      this.set(name, value);
    }
  }

  delete(name: string): void {
    this.#entries.delete(name.toLowerCase());
  }

  lines(): string[] {
    return [...this.#entries.values()].map(
      ({ name, value }) => `${withoutNewlines(name)}: ${withoutNewlines(value)}`,
    );
  }
}

/**
 * A header can't be allowed to end the line it is on: a credential that
 * arrived from somewhere else with a CRLF in it would otherwise write headers
 * of its own into the request. Go's `http.Request.Write` turns both into
 * spaces, and so does this.
 */
function withoutNewlines(value: string): string {
  return value.replaceAll("\r", " ").replaceAll("\n", " ");
}

export function parseResponse(head: Buffer): UpgradeResponse {
  const [statusLine = "", ...headerLines] = head.toString("latin1").split("\r\n");
  const match = /^HTTP\/1\.[01] (\d{3})(?: (.*))?$/.exec(statusLine);
  if (match === null) {
    throw new Error(
      `actioncable: the server's response is not HTTP: ${JSON.stringify(statusLine)}`,
    );
  }

  const statusCode = Number(match[1]);
  const headers = new Map<string, string>();
  for (const line of headerLines) {
    const separator = line.indexOf(":");
    if (separator === -1) {
      continue;
    }

    const name = line.slice(0, separator).trim().toLowerCase();
    const value = line.slice(separator + 1).trim();
    const existing = headers.get(name);
    headers.set(name, existing === undefined ? value : `${existing}, ${value}`);
  }

  return { statusCode, status: `${statusCode} ${match[2] ?? ""}`.trim(), headers };
}

export function verifyUpgrade(response: UpgradeResponse, key: string): void {
  if (response.statusCode !== 101) {
    throw new HandshakeError(response.statusCode, response.status);
  }

  const upgrade = response.headers.get("upgrade") ?? "";
  if (upgrade.toLowerCase() !== "websocket") {
    throw new Error(
      `actioncable: server did not upgrade to websocket (Upgrade: ${JSON.stringify(upgrade)})`,
    );
  }

  const connection = response.headers.get("connection") ?? "";
  if (!contains(connection, "upgrade")) {
    throw new Error(
      `actioncable: server did not upgrade the connection (Connection: ${JSON.stringify(connection)})`,
    );
  }

  const accepted = response.headers.get("sec-websocket-accept") ?? "";
  if (accepted !== acceptKey(key)) {
    throw new Error(
      `actioncable: server sent a bad Sec-WebSocket-Accept: ${JSON.stringify(accepted)}`,
    );
  }

  const extensions = response.headers.get("sec-websocket-extensions") ?? "";
  if (extensions !== "") {
    throw new Error(
      `actioncable: server negotiated unrequested extensions: ${JSON.stringify(extensions)}`,
    );
  }
}

function contains(header: string, token: string): boolean {
  return header.split(",").some((value) => value.trim().toLowerCase() === token);
}
