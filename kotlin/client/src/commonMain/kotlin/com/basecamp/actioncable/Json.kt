package com.basecamp.actioncable

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Turns the loosely typed values a caller hands to an identifier, an action or
 * a send into JSON.
 *
 * Go reflects over whatever `any` it was given and fails on a type that has no
 * JSON form. There is no reflection here, so the types are named: the scalars,
 * a list, a map with string keys, and anything already a [JsonElement] — which
 * is how a caller with a `@Serializable` class passes it, through
 * `Json.encodeToJsonElement`. Anything else is a caller error, and saying so
 * beats guessing.
 */
internal fun jsonOf(value: Any?, describe: () -> String): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Enum<*> -> JsonPrimitive(value.name)
    is Map<*, *> -> jsonObjectOf(value, describe)
    is Iterable<*> -> JsonArray(value.map { jsonOf(it, describe) })
    is Array<*> -> JsonArray(value.map { jsonOf(it, describe) })
    else -> throw ActionCableException("actioncable: ${describe()} has no JSON form: ${value::class.simpleName}")
}

private fun jsonObjectOf(value: Map<*, *>, describe: () -> String): JsonObject {
    val fields =
        value.entries.associate { (name, field) ->
            if (name !is String) {
                throw ActionCableException("actioncable: ${describe()} must be keyed by strings, got $name")
            }

            name to jsonOf(field, describe)
        }

    return sortedJsonObject(fields)
}

/**
 * A JSON object with its keys in order. Go's `encoding/json` writes a map
 * sorted, and an identifier's encoding is the key the server files the
 * subscription under, so the same subscription has to key the same here.
 * Everything this client builds from a map goes through here, so no payload
 * depends on which order a caller happened to write its fields in.
 */
internal fun sortedJsonObject(fields: Map<String, JsonElement>): JsonObject =
    JsonObject(fields.entries.sortedBy { it.key }.associate { it.key to it.value })
