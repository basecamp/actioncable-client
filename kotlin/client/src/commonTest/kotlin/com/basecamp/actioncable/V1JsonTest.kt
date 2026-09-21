package com.basecamp.actioncable

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class V1JsonTest {
    @Test
    fun `subprotocol`() {
        assertEquals("actioncable-v1-json", V1Json.subprotocol)
    }

    @Test
    fun `encode`() {
        val commands =
            listOf(
                Command(CommandName.SUBSCRIBE, """{"channel":"RoomChannel"}""") to
                    """{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\"}"}""",
                Command(CommandName.UNSUBSCRIBE, """{"channel":"RoomChannel"}""") to
                    """{"command":"unsubscribe","identifier":"{\"channel\":\"RoomChannel\"}"}""",
                Command(CommandName.MESSAGE, """{"channel":"RoomChannel"}""", """{"action":"speak"}""") to
                    """{"command":"message","identifier":"{\"channel\":\"RoomChannel\"}","data":"{\"action\":\"speak\"}"}""",
            )

        commands.forEach { (command, encoded) ->
            assertEquals(encoded, V1Json.encode(command).decodeToString())
        }
    }

    @Test
    fun `decode`() {
        val frames =
            listOf(
                """{"type":"welcome"}""" to Incoming(Kind.WELCOME),
                """{"type":"ping","message":1755400000}""" to Incoming(Kind.PING, message = Message("1755400000")),
                """{"type":"disconnect","reason":"server_restart","reconnect":true}""" to
                    Incoming(Kind.DISCONNECT, reason = DisconnectReason.SERVER_RESTART, reconnect = true),
                """{"type":"confirm_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}""" to
                    Incoming(Kind.CONFIRMATION, identifier = """{"channel":"RoomChannel"}"""),
                """{"type":"reject_subscription","identifier":"{\"channel\":\"RoomChannel\"}"}""" to
                    Incoming(Kind.REJECTION, identifier = """{"channel":"RoomChannel"}"""),
                """{"identifier":"{\"channel\":\"RoomChannel\"}","message":{"body":"Hello!"}}""" to
                    Incoming(
                        Kind.MESSAGE,
                        identifier = """{"channel":"RoomChannel"}""",
                        message = Message("""{"body":"Hello!"}"""),
                    ),
                """{"type":"something_new","identifier":"x","message":"anything"}""" to
                    Incoming(Kind.MESSAGE, identifier = "x", message = Message(""""anything"""")),
            )

        frames.forEach { (payload, expected) ->
            val incoming = V1Json.decode(payload.encodeToByteArray())

            assertEquals(expected.kind, incoming.kind, payload)
            assertEquals(expected.identifier, incoming.identifier, payload)
            assertEquals(expected.message.json, incoming.message.json, payload)
            assertEquals(expected.reason, incoming.reason, payload)
            assertEquals(expected.reconnect, incoming.reconnect, payload)
        }
    }

    @Test
    fun `decode garbage`() {
        assertFailsWith<ActionCableException> { V1Json.decode("not json".encodeToByteArray()) }
    }
}
