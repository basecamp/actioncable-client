package com.basecamp.actioncable

/**
 * The headers an upgrade request carries. An Action Cable server authorizes
 * that request, so this is where a session cookie or a bearer token goes.
 *
 * Header names are compared without regard to case, the way HTTP does, and one
 * name may carry several values. Instances are immutable: what a client was
 * given at construction is what it dials with, however the caller's own map is
 * edited afterwards.
 */
class Headers private constructor(private val entries: Map<String, List<String>>) {
    companion object {
        val EMPTY = Headers(emptyMap())

        fun of(vararg headers: Pair<String, String>): Headers = from(headers.groupBy({ it.first }, { it.second }))

        /**
         * Takes a copy of [headers]. A value carrying a carriage return or a
         * newline would be two headers by the time it reached the server, so
         * each is turned into a space before it is stored — the same thing Go's
         * `net/http` does when it writes a request.
         */
        fun from(headers: Map<String, List<String>>): Headers = Headers(
            headers.entries.associate { (name, values) -> name to values.map(::neutralize) },
        )

        private fun neutralize(value: String): String = value.map { if (it == '\r' || it == '\n') ' ' else it }.joinToString("")
    }

    val names: Set<String> get() = entries.keys

    val isEmpty: Boolean get() = entries.isEmpty()

    /** The first value for [name], or null when the header is absent. */
    operator fun get(name: String): String? = valuesOf(name).firstOrNull()

    fun values(name: String): List<String> = valuesOf(name)

    /** This set of headers with [name] replaced by the one value given. */
    fun with(name: String, value: String): Headers =
        from(entries.filterKeys { !it.equals(name, ignoreCase = true) } + (name to listOf(value)))

    /**
     * This set of headers with [other] laid over it, name by name. It is how a
     * credential asked for on every dial keeps the Origin and the API token
     * that were set once.
     */
    fun overlaidWith(other: Headers): Headers {
        val kept = entries.filterKeys { name -> other.names.none { it.equals(name, ignoreCase = true) } }

        return Headers(kept + other.entries)
    }

    fun forEach(action: (name: String, value: String) -> Unit) {
        entries.forEach { (name, values) -> values.forEach { action(name, it) } }
    }

    private fun valuesOf(name: String): List<String> =
        entries.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value ?: emptyList()

    override fun toString(): String = entries.toString()
}
