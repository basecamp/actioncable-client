package com.basecamp.actioncable

/**
 * Takes the client's chatter — dropped messages, failed connections, retries.
 * Nothing is logged by default.
 */
fun interface Logger {
    fun log(message: String)

    companion object {
        /** Throws everything away, which is what a client does unless told otherwise. */
        val NONE = Logger { }
    }
}
