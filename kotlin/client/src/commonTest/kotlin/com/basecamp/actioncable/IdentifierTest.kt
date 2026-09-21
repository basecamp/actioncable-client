package com.basecamp.actioncable

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class IdentifierTest {
    @Test
    fun `key`() {
        val identifiers =
            listOf(
                Identifier("RoomChannel") to """{"channel":"RoomChannel"}""",
                Identifier("RoomChannel", mapOf("id" to 42)) to """{"channel":"RoomChannel","id":42}""",
                Identifier("RoomChannel", mapOf("id" to 42, "since" to "yesterday")) to
                    """{"channel":"RoomChannel","id":42,"since":"yesterday"}""",
            )

        identifiers.forEach { (identifier, key) ->
            assertEquals(key, identifier.key)
            assertEquals(key, identifier.toString(), "toString should be the key")
        }
    }

    @Test
    fun `key refuses params it cannot encode`() {
        val identifier = Identifier("RoomChannel", mapOf("id" to Regex("nope")))

        assertFailsWith<ActionCableException> { identifier.key }
    }
}
