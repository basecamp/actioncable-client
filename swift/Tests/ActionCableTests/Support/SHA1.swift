import Foundation

/// SHA-1, for the one thing the loopback server needs it for: the
/// `Sec-WebSocket-Accept` an RFC 6455 handshake answers with. CryptoKit is
/// Apple-only and swift-crypto is a dependency, and the client itself needs
/// neither — `URLSession` does its own handshake.
enum SHA1 {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]

        for block in padded(message) {
            var schedule = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                schedule[index] =
                    UInt32(block[index * 4]) << 24 | UInt32(block[index * 4 + 1]) << 16
                    | UInt32(block[index * 4 + 2]) << 8 | UInt32(block[index * 4 + 3])
            }
            for index in 16..<80 {
                schedule[index] = rotated(
                    schedule[index - 3] ^ schedule[index - 8] ^ schedule[index - 14] ^ schedule[index - 16],
                    by: 1
                )
            }

            var (a, b, c, d, e) = (state[0], state[1], state[2], state[3], state[4])

            for index in 0..<80 {
                let (mixed, constant) = round(index, b, c, d)
                let next = rotated(a, by: 5) &+ mixed &+ e &+ constant &+ schedule[index]
                (e, d, c, b, a) = (d, c, rotated(b, by: 30), a, next)
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
        }

        return state.flatMap { word in
            [
                UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word),
            ]
        }
    }

    private static func round(_ index: Int, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> (UInt32, UInt32) {
        switch index {
        case 0..<20:
            return ((b & c) | (~b & d), 0x5A82_7999)
        case 20..<40:
            return (b ^ c ^ d, 0x6ED9_EBA1)
        case 40..<60:
            return ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
        default:
            return (b ^ c ^ d, 0xCA62_C1D6)
        }
    }

    private static func rotated(_ word: UInt32, by places: UInt32) -> UInt32 {
        (word << places) | (word >> (32 - places))
    }

    private static func padded(_ message: [UInt8]) -> [[UInt8]] {
        var padded = message
        let bits = UInt64(message.count) * 8

        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }

        return stride(from: 0, to: padded.count, by: 64).map { Array(padded[$0..<$0 + 64]) }
    }
}

func webSocketAccept(for key: String) -> String {
    let combined = Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)

    return Data(SHA1.digest(combined)).base64EncodedString()
}
