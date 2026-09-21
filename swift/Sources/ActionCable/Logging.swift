/// Takes the client's chatter — dropped messages, failed connections, retries.
/// Nothing is logged by default.
///
/// It is `CableLogger` rather than `Logger` because both `os` and swift-log
/// already own that name on the platforms this package runs on.
public protocol CableLogger: Sendable {
    func log(_ message: String)
}

/// Adapts a function to ``CableLogger``.
public struct CableLoggerFunction: CableLogger {
    private let write: @Sendable (String) -> Void

    public init(_ write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    public func log(_ message: String) {
        write(message)
    }
}
