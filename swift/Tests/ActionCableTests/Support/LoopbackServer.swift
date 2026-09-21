import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let opContinuation: UInt8 = 0x0
let opText: UInt8 = 0x1
let opBinary: UInt8 = 0x2
let opClose: UInt8 = 0x8
let opPing: UInt8 = 0x9
let opPong: UInt8 = 0xa

struct WebSocketFrame: Sendable {
    var final: Bool
    var opcode: UInt8
    var payload: [UInt8]

    var text: String {
        String(decoding: payload, as: UTF8.self)
    }
}

enum LoopbackError: Error, CustomStringConvertible {
    case setup(String)
    case noClientConnected
    case closed
    case unexpectedFrame(String)

    var description: String {
        switch self {
        case .setup(let what):
            return "could not start the loopback server: \(what)"
        case .noClientConnected:
            return "no client connected"
        case .closed:
            return "the peer went away"
        case .unexpectedFrame(let what):
            return what
        }
    }
}

/// Speaks just enough of the server side of RFC 6455 to exercise the
/// transport: it does the handshake by hand and then hands the raw socket over.
///
/// POSIX sockets rather than `Network.framework`, which is Apple-only, and
/// rather than any package, which would be a dependency.
final class LoopbackServer: @unchecked Sendable {
    /// What the handshake answers with.
    enum Handshake: Sendable {
        case upgrade
        case badAccept
        case refuse(status: Int, phrase: String)
        case redirect
    }

    let port: UInt16

    private let listener: Int32
    private let mutex = NSLock()
    private var handshake: Handshake = .upgrade
    private var waiting: [PeerConnection] = []
    private var running = true

    init(handshake: Handshake = .upgrade) throws {
        self.handshake = handshake

        let bound = socket(AF_INET, sockStream, 0)
        if bound < 0 {
            throw LoopbackError.setup("socket")
        }

        var reuse: Int32 = 1
        setsockopt(bound, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let named = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(bound, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if named < 0 {
            close(bound)
            throw LoopbackError.setup("bind")
        }
        if listen(bound, 8) < 0 {
            close(bound)
            throw LoopbackError.setup("listen")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let asked = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(bound, $0, &length)
            }
        }
        if asked < 0 {
            close(bound)
            throw LoopbackError.setup("getsockname")
        }

        listener = bound
        port = UInt16(bigEndian: assigned.sin_port)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func url(path: String = "/cable") -> String {
        "ws://127.0.0.1:\(port)\(path)"
    }

    /// Waits for a client to complete the handshake, and hands back the socket
    /// to play the server on.
    func accept(timeout: TimeInterval = wait) async throws -> PeerConnection {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let peer = takeWaiting() {
                return peer
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        throw LoopbackError.noClientConnected
    }

    func stop() {
        mutex.lock()
        running = false
        let peers = waiting
        waiting = []
        mutex.unlock()

        for peer in peers {
            peer.hangUp()
        }
        close(listener)
    }

    private func takeWaiting() -> PeerConnection? {
        mutex.lock()
        defer { mutex.unlock() }

        if waiting.isEmpty {
            return nil
        } else {
            return waiting.removeFirst()
        }
    }

    private func acceptLoop() {
        while true {
            let socket = acceptSocket(listener)
            if socket < 0 {
                return
            }

            mutex.lock()
            let alive = running
            let answer = handshake
            mutex.unlock()

            if !alive {
                close(socket)
                return
            }

            Thread.detachNewThread { [weak self] in
                self?.greet(socket, with: answer)
            }
        }
    }

    private func greet(_ socket: Int32, with answer: Handshake) {
        noSignalPipe(socket)

        guard let request = PeerConnection.readRequest(socket) else {
            close(socket)
            return
        }

        switch answer {
        case .refuse(let status, let phrase):
            sendBytes(socket, Array("HTTP/1.1 \(status) \(phrase)\r\nContent-Length: 13\r\n\r\nno cable here".utf8))
            close(socket)
        case .redirect:
            sendBytes(socket, Array("HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n".utf8))
            close(socket)
        case .upgrade, .badAccept:
            var accepted = webSocketAccept(for: request.headers["sec-websocket-key"] ?? "")
            if case .badAccept = answer {
                accepted = "obviously-wrong"
            }

            var response = "HTTP/1.1 101 Switching Protocols\r\n"
            response += "Upgrade: websocket\r\n"
            response += "Connection: Upgrade\r\n"
            response += "Sec-WebSocket-Accept: \(accepted)\r\n"
            if let offered = request.headers["sec-websocket-protocol"] {
                response +=
                    "Sec-WebSocket-Protocol: \(offered.split(separator: ",")[0].trimmingCharacters(in: .whitespaces))\r\n"
            }
            response += "\r\n"

            sendBytes(socket, Array(response.utf8))

            mutex.lock()
            waiting.append(PeerConnection(socket: socket, request: request))
            mutex.unlock()
        }
    }
}

struct PeerRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
}

/// One accepted socket, with the frame reading and writing a test needs to
/// play the server.
final class PeerConnection: @unchecked Sendable {
    let request: PeerRequest

    private let socket: Int32
    private let mutex = NSLock()
    private var pending: [UInt8] = []
    private var hungUp = false

    init(socket: Int32, request: PeerRequest) {
        self.socket = socket
        self.request = request
    }

    func hangUp() {
        mutex.lock()
        let first = !hungUp
        hungUp = true
        mutex.unlock()

        if first {
            close(socket)
        }
    }

    /// The next text frame's payload.
    func read(timeout: TimeInterval = wait) async throws -> String {
        let frame = try await readFrame(timeout: timeout)

        if frame.opcode == opText {
            return frame.text
        } else {
            throw LoopbackError.unexpectedFrame("expected a text frame, got opcode \(frame.opcode)")
        }
    }

    func readFrame(timeout: TimeInterval = wait) async throws -> WebSocketFrame {
        try await offCooperativePool { try self.nextFrame(timeout: timeout) }
    }

    func write(_ opcode: UInt8, _ payload: [UInt8]) async throws {
        try await writeFragment(opcode, payload, final: true)
    }

    func write(_ opcode: UInt8, _ text: String) async throws {
        try await writeFragment(opcode, Array(text.utf8), final: true)
    }

    func writeFragment(_ opcode: UInt8, _ payload: [UInt8], final: Bool) async throws {
        var building: [UInt8] = [opcode]
        if final {
            building[0] |= 0x80
        }

        switch payload.count {
        case ...125:
            building.append(UInt8(payload.count))
        case ...0xffff:
            building.append(126)
            building.append(contentsOf: bigEndian(UInt16(payload.count)))
        default:
            building.append(127)
            building.append(contentsOf: bigEndian(UInt64(payload.count)))
        }

        let frame = building + payload
        _ = try await offCooperativePool { self.write(frame) }
    }

    /// Sends a frame the way only a client is allowed to: masked.
    func writeMasked(_ opcode: UInt8, _ payload: [UInt8]) async throws {
        let mask: [UInt8] = [1, 2, 3, 4]
        let masked = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let frame: [UInt8] = [0x80 | opcode, 0x80 | UInt8(payload.count)] + mask + masked

        _ = try await offCooperativePool { self.write(frame) }
    }

    /// Counts the close frames the client sends before it goes away.
    func closeFrames(timeout: TimeInterval = wait) async throws -> Int {
        try await offCooperativePool {
            var closes = 0

            while true {
                guard let frame = try? self.nextFrame(timeout: timeout) else {
                    return closes
                }
                if frame.opcode == opClose {
                    closes += 1
                }
            }
        }
    }

    // MARK: - The socket

    private func nextFrame(timeout: TimeInterval) throws -> WebSocketFrame {
        let header = try take(2, timeout: timeout)
        var frame = WebSocketFrame(final: header[0] & 0x80 != 0, opcode: header[0] & 0x0f, payload: [])

        if header[1] & 0x80 == 0 {
            throw LoopbackError.unexpectedFrame("the client sent an unmasked frame")
        }

        var length = Int(header[1] & 0x7f)
        if length == 126 {
            let extended = try take(2, timeout: timeout)
            length = Int(extended[0]) << 8 | Int(extended[1])
        } else if length == 127 {
            let extended = try take(8, timeout: timeout)
            length = extended.reduce(0) { $0 << 8 | Int($1) }
        }

        let mask = try take(4, timeout: timeout)
        let masked = try take(length, timeout: timeout)
        frame.payload = masked.enumerated().map { $0.element ^ mask[$0.offset % 4] }

        return frame
    }

    private func take(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)

        while pending.count < count {
            if Date() >= deadline {
                throw LoopbackError.closed
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            setReadTimeout(min(0.25, timeout))
            let read = recv(socket, &buffer, buffer.count, 0)

            if read > 0 {
                pending.append(contentsOf: buffer[0..<read])
            } else if read == 0 {
                throw LoopbackError.closed
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw LoopbackError.closed
            }
        }

        let taken = Array(pending[0..<count])
        pending.removeFirst(count)

        return taken
    }

    private func setReadTimeout(_ seconds: TimeInterval) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    private func write(_ bytes: [UInt8]) -> Bool {
        sendBytes(socket, bytes)
    }

    static func readRequest(_ socket: Int32) -> PeerRequest? {
        var received: [UInt8] = []
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while !contains(received, Array("\r\n\r\n".utf8)) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let read = recv(socket, &buffer, buffer.count, 0)
            if read <= 0 {
                return nil
            }
            received.append(contentsOf: buffer[0..<read])
        }

        let lines = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        var headers: [String: String] = [:]

        for line in lines.dropFirst() where line.contains(": ") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        return PeerRequest(
            method: start.first ?? "",
            path: start.count > 1 ? start[1] : "",
            headers: headers
        )
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else {
            return false
        }

        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }

        return false
    }
}

private func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func bigEndian(_ value: UInt64) -> [UInt8] {
    stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> UInt64($0)) }
}

func closePayload(_ code: UInt16, _ reason: String = "") -> [UInt8] {
    bigEndian(code) + Array(reason.utf8)
}

func closeCode(of frame: WebSocketFrame) -> UInt16 {
    UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
}

/// Runs blocking socket work somewhere other than the cooperative pool, whose
/// threads Swift expects never to block.
private func acceptSocket(_ listener: Int32) -> Int32 {
    accept(listener, nil, nil)
}

@discardableResult
private func sendBytes(_ socket: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0

    while sent < bytes.count {
        let wrote = bytes[sent...].withUnsafeBufferPointer {
            send(socket, $0.baseAddress, $0.count, sendFlags)
        }
        if wrote <= 0 {
            return false
        }
        sent += wrote
    }

    return true
}

func offCooperativePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try body() })
        }
    }
}

#if canImport(Darwin)
private let sockStream = SOCK_STREAM
private let sendFlags: Int32 = 0

private func noSignalPipe(_ socket: Int32) {
    var on: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}
#else
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let sendFlags = Int32(MSG_NOSIGNAL)

private func noSignalPipe(_ socket: Int32) {}
#endif
