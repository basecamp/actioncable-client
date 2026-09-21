package com.basecamp.actioncable

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Runs a subscription's callbacks on their own coroutine, one at a time, in the
 * order the events happened.
 *
 * Callbacks belong off the connection's coroutine: an `onDisconnected` calling
 * close or an `onConnected` calling subscribe are both reasonable things to
 * write, and both wait on work only the connection can do. The queue is
 * unbounded for the same reason — handing an event over must never block the
 * connection.
 *
 * Once stopped it runs what it still holds, turns away anything handed to it
 * after that, then calls [afterStop]. That is how a subscription ends its
 * message flow only after its last callback has returned, with none left behind
 * unrun.
 */
internal class Dispatcher(scope: CoroutineScope, private val afterStop: suspend () -> Unit) {
    private val pending = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private val mutex = Mutex()
    private var stopping = false

    init {
        scope.launch { run() }
    }

    suspend fun dispatch(callback: suspend () -> Unit) {
        mutex.withLock {
            if (!stopping) {
                pending.trySend(callback)
            }
        }
    }

    /**
     * Lets the dispatcher finish what it has and go away. It doesn't wait,
     * since a callback is allowed to be what stopped it.
     */
    suspend fun stop() {
        mutex.withLock {
            if (!stopping) {
                stopping = true
                pending.close()
            }
        }
    }

    private suspend fun run() {
        for (callback in pending) {
            callback()
        }

        afterStop()
    }
}
