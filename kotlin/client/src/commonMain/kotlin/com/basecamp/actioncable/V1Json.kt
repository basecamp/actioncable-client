package com.basecamp.actioncable

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** The subprotocol every Rails Action Cable server speaks. */
const val SUBPROTOCOL_V1_JSON = "actioncable-v1-json"

/**
 * The actioncable-v1-json protocol: JSON objects in text frames, keyed by
 * command going out and by type coming in.
 */
object V1Json : Protocol {
    override val subprotocol = SUBPROTOCOL_V1_JSON

    private val format = Json { ignoreUnknownKeys = true }

    override fun encode(command: Command): ByteArray {
        val fields =
            buildMap {
                put("command", JsonPrimitive(command.name.wire))
                put("identifier", JsonPrimitive(command.identifier))
                if (command.data.isNotEmpty()) {
                    put("data", JsonPrimitive(command.data))
                }
            }

        return JsonObject(fields).toString().encodeToByteArray()
    }

    override fun decode(payload: ByteArray): Incoming {
        val text = payload.decodeToString()
        val frame =
            try {
                format.parseToJsonElement(text) as JsonObject
            } catch (parse: Exception) {
                throw ActionCableException("actioncable: decoding ${truncate(text, 200)}", parse)
            }

        return Incoming(
            kind = kindOf(frame.stringOf("type")),
            identifier = frame.stringOf("identifier"),
            message = frame["message"]?.let { Message(it.toString()) } ?: Message.EMPTY,
            reason = frame.stringOf("reason"),
            reconnect = frame["reconnect"]?.jsonPrimitive?.booleanOrNull ?: false,
        )
    }

    /**
     * Anything without a recognized type is a channel message, which is how the
     * server sends them: an identifier and a message, and no type at all.
     */
    private fun kindOf(type: String): Kind = when (type) {
        Kind.WELCOME.wire -> Kind.WELCOME
        Kind.PING.wire -> Kind.PING
        Kind.DISCONNECT.wire -> Kind.DISCONNECT
        Kind.CONFIRMATION.wire -> Kind.CONFIRMATION
        Kind.REJECTION.wire -> Kind.REJECTION
        else -> Kind.MESSAGE
    }

    private fun JsonObject.stringOf(name: String): String = this[name]?.jsonPrimitive?.contentOrNull ?: ""

    private fun truncate(payload: String, limit: Int): String = if (payload.length > limit) {
        payload.take(limit) + "…"
    } else {
        payload
    }
}
