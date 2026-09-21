import { randomFillSync } from "node:crypto";
import { CloseError } from "../../errors.js";

export const OPCODE = {
  continuation: 0x0,
  text: 0x1,
  binary: 0x2,
  close: 0x8,
  ping: 0x9,
  pong: 0xa,
} as const;

export type Opcode = (typeof OPCODE)[keyof typeof OPCODE];

export interface Frame {
  final: boolean;
  opcode: number;
  payload: Buffer;
}

/**
 * RFC 6455 §7.4.1's two codes this side needs by name: the one a close frame
 * carries by default, and the one that stands in for a frame carrying none.
 */
export const CLOSE_NORMAL = 1000;
export const CLOSE_NO_STATUS = 1005;

/**
 * What fits in a close frame after the code: a control frame's payload is at
 * most 125 bytes.
 */
const MAX_CLOSE_REASON_BYTES = 123;

/** One frame as a client sends it: final, and masked. */
export function encodeFrame(opcode: number, payload: Buffer): Buffer {
  const mask = Buffer.allocUnsafe(4);
  randomFillSync(mask);

  const header = headerFor(opcode, payload.length);
  const masked = Buffer.from(payload);
  applyMask(mask, masked);

  return Buffer.concat([header, mask, masked]);
}

function headerFor(opcode: number, length: number): Buffer {
  if (length <= 125) {
    return Buffer.from([0x80 | opcode, 0x80 | length]);
  }

  if (length <= 0xffff) {
    const header = Buffer.allocUnsafe(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
    return header;
  }

  const header = Buffer.allocUnsafe(10);
  header[0] = 0x80 | opcode;
  header[1] = 0x80 | 127;
  header.writeBigUInt64BE(BigInt(length), 2);

  return header;
}

export function applyMask(mask: Buffer, payload: Buffer): void {
  for (let index = 0; index < payload.length; index += 1) {
    payload[index] = (payload[index] as number) ^ (mask[index % 4] as number);
  }
}

/**
 * A close frame's payload: the code, then as much of the reason as a control
 * frame has room for.
 */
export function closePayload(code: number, reason: string): Buffer {
  let text = Buffer.from(reason, "utf8");
  if (text.length > MAX_CLOSE_REASON_BYTES) {
    text = text.subarray(0, MAX_CLOSE_REASON_BYTES);
  }

  const payload = Buffer.allocUnsafe(2 + text.length);
  payload.writeUInt16BE(code, 0);
  text.copy(payload, 2);

  return payload;
}

/**
 * The close frame sent back for one the server sent: its own code echoed when
 * we're allowed to send it ourselves — normal, going away, or an
 * application's own — and normal closure otherwise.
 */
export function closeReply(received: Buffer): Buffer {
  let code = CLOSE_NORMAL;

  if (received.length >= 2) {
    const echoed = received.readUInt16BE(0);
    if (echoed >= 3000 || echoed === CLOSE_NORMAL || echoed === 1001) {
      code = echoed;
    }
  }

  return closePayload(code, "");
}

export function closeErrorFrom(payload: Buffer): CloseError {
  if (payload.length < 2) {
    return new CloseError(CLOSE_NO_STATUS);
  } else {
    return new CloseError(payload.readUInt16BE(0), payload.subarray(2).toString("utf8"));
  }
}
