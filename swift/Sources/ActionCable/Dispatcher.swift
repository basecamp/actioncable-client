/// Runs a subscription's callbacks on a task of their own, one at a time, in
/// the order the events happened.
///
/// Callbacks belong off the connection's task: `onDisconnected` calling `close`
/// or `onConnected` calling `subscribe` are both reasonable things to write,
/// and both wait on work only the client can do. The queue is unbounded for the
/// same reason — handing an event over must never block the connection.
///
/// Once stopped it runs what it still holds, turns away anything handed to it
/// after that, then calls `afterStop`. That is how a subscription ends its
/// message stream only after its last callback has returned, with none left
/// behind unrun.
final class Dispatcher: Sendable {
    private let queue: AsyncStream<@Sendable () async -> Void>.Continuation

    init(afterStop: @escaping @Sendable () -> Void) {
        var continuation: AsyncStream<@Sendable () async -> Void>.Continuation!
        let callbacks = AsyncStream<@Sendable () async -> Void>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        queue = continuation

        Task {
            for await callback in callbacks {
                await callback()
            }

            afterStop()
        }
    }

    func dispatch(_ callback: @escaping @Sendable () async -> Void) {
        queue.yield(callback)
    }

    /// Lets the dispatcher finish what it has and go away. It doesn't wait,
    /// since a callback is allowed to be what stopped it.
    func stop() {
        queue.finish()
    }
}
