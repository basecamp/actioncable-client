/**
 * The extra attributes that identify a subscription alongside its channel
 * name, like the id of the record a channel streams for.
 */
export type Params = Record<string, unknown>;

/**
 * Names one subscription. It is encoded as a JSON object and the server treats
 * that encoding as an opaque key, echoing it back on every frame it sends for
 * the subscription.
 *
 * ```ts
 * { channel: "RoomChannel", params: { id: 42 } }
 * ```
 *
 * A channel with no params needs only the name.
 */
export interface Identifier {
  channel: string;
  params?: Params;
}

/**
 * The JSON identifier string the server knows a subscription by, and the one
 * it echoes back on everything it sends for it.
 *
 * The keys are sorted, which is what Go's `json.Marshal` of a map does and so
 * what the Go client puts on the wire. The server treats the string as opaque,
 * so the order only has to be stable — but sorting means the same identifier
 * keys the same subscription whichever client built it.
 */
export function identifierKey(identifier: Identifier): string {
  const fields = { ...identifier.params, channel: identifier.channel };

  try {
    return JSON.stringify(sortedDeeply(fields));
  } catch (cause) {
    throw new TypeError(`actioncable: encoding identifier for ${identifier.channel}`, { cause });
  }
}

function sortedDeeply(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortedDeeply);
  } else if (isPlainObject(value)) {
    const sorted: Params = {};
    for (const key of Object.keys(value).sort()) {
      sorted[key] = sortedDeeply(value[key]);
    }
    return sorted;
  } else {
    return value;
  }
}

function isPlainObject(value: unknown): value is Params {
  if (value === null || typeof value !== "object") {
    return false;
  }

  const prototype: unknown = Object.getPrototypeOf(value);

  return prototype === Object.prototype || prototype === null;
}
