package com.basecamp.actioncable

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlin.jvm.JvmInline

/**
 * The undecoded payload a channel broadcast or transmitted. Its shape is
 * entirely up to the channel, so [decode] it into the type that channel sends.
 */
@JvmInline
value class Message(val json: String) {
    companion object {
        val EMPTY = Message("")

        @PublishedApi
        internal val format = Json { ignoreUnknownKeys = true }
    }

    /** The payload as the type the channel sends. */
    inline fun <reified T> decode(): T = format.decodeFromString<T>(json)

    /** The payload as a JSON tree, for a channel whose shape isn't a class here. */
    fun toJsonElement(): JsonElement = format.parseToJsonElement(json)

    override fun toString(): String = json
}
