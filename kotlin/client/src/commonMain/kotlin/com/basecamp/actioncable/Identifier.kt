package com.basecamp.actioncable

/**
 * Names one subscription. It is encoded as a JSON object and the server treats
 * that encoding as an opaque key, echoing it back on every frame it sends for
 * the subscription.
 *
 * ```
 * Identifier("RoomChannel", mapOf("id" to 42))
 * ```
 *
 * A channel with no params needs only the name. [params] takes the scalars, a
 * list, a map, or a `JsonElement` for anything else; a value with no JSON form
 * is refused when the key is built.
 */
class Identifier(val channel: String, val params: Map<String, Any?> = emptyMap()) {
    /** The JSON the server knows this subscription by. */
    val key: String by lazy {
        jsonOf(params + ("channel" to channel)) { "the params of $channel" }.toString()
    }

    override fun toString(): String = key

    override fun equals(other: Any?): Boolean = other is Identifier && other.channel == channel && other.params == params

    override fun hashCode(): Int = 31 * channel.hashCode() + params.hashCode()
}
