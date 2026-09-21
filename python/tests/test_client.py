from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest
from conftest import (
    ROOM_IDENTIFIER,
    NewClient,
    ended,
    receive,
    room,
    start,
    still_running,
    stopped,
    subscribed,
    welcomed,
)

from actioncable import (
    REASON_UNAUTHORIZED,
    SUBPROTOCOL_UNSUPPORTED,
    SUBPROTOCOL_V1_JSON,
    V1JSON,
    ActionCableError,
    Client,
    ClosedError,
    CommandName,
    DisconnectError,
    GaveUpError,
    Identifier,
    NotConnectedError,
    RejectedError,
    UnsubscribedError,
    UnsupportedSubprotocolError,
)
from actioncable.testing import FakeProtocol, FakeTransport

FAST = (0.001, 0.001)

OTHER_IDENTIFIER = '{"channel":"OtherChannel"}'


async def test_connect_waits_for_the_welcome(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)

    connecting = start(client.connect())
    conn = await transport.accept()

    await still_running(connecting)

    await conn.welcome()
    await connecting
    assert client.connected, "client is not connected after the welcome"


async def test_connect_retries_until_the_server_answers(transport: FakeTransport, new_client: NewClient) -> None:
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))
    client = new_client(transport, backoff=FAST)

    connecting = start(client.connect())
    await (await transport.accept()).welcome()

    await connecting


async def test_subscribe_receives_messages(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    connections: list[bool] = []
    subscribing = start(client.subscribe(room(), on_connected=connections.append))

    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)

    subscription = await subscribing
    await asyncio.sleep(0)
    assert connections == [False], "first connection reported itself as a reconnect"

    await conn.push(f'{{"identifier":{_quote(ROOM_IDENTIFIER)},"message":{{"body":"Hello!"}}}}')

    assert (await receive(subscription)).json() == {"body": "Hello!"}


async def test_subscribe_rejected(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    rejections: list[bool] = []
    subscribing = start(client.subscribe(room(), on_rejected=lambda: rejections.append(True)))

    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.reject(ROOM_IDENTIFIER)

    with pytest.raises(RejectedError):
        await subscribing

    await asyncio.sleep(0)
    assert rejections == [True], "on_rejected was never called"


async def test_perform_sends_an_action(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await subscription.perform("speak", {"body": "Hello!"})

    command = await conn.expect_command(CommandName.MESSAGE, ROOM_IDENTIFIER)
    assert command.data == '{"action":"speak","body":"Hello!"}', "expected the action alongside the data"


async def test_send_delivers_data_without_an_action(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await subscription.send({"body": "Hello!"})

    command = await conn.expect_command(CommandName.MESSAGE, ROOM_IDENTIFIER)
    assert command.data == '{"body":"Hello!"}', "expected the data on its own"


async def test_send_refuses_data_that_cannot_encode(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    with pytest.raises(ActionCableError):
        await subscription.send(object())


async def test_perform_refuses_data_that_is_not_an_object(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    with pytest.raises(ActionCableError):
        await subscription.perform("speak", ["nope"])


async def test_unsubscribe_closes_messages_and_tells_the_server(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await subscription.unsubscribe()
    await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)

    await ended(subscription)


async def test_reconnect_resubscribes(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    connections: asyncio.Queue[bool] = asyncio.Queue()
    disconnections: asyncio.Queue[bool] = asyncio.Queue()
    subscribing = start(
        client.subscribe(
            room(),
            on_connected=connections.put_nowait,
            on_disconnected=disconnections.put_nowait,
        )
    )
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing
    await connections.get()

    await conn.close()

    assert await disconnections.get(), "disconnect reported that the client would not reconnect"

    reconnected = await transport.accept()
    await reconnected.welcome()
    await reconnected.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await reconnected.confirm(ROOM_IDENTIFIER)

    assert await connections.get(), "expected the confirmation after a reconnect to report reconnected"


async def test_stale_connection_is_replaced(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, stale_after=0.075, backoff=FAST)

    connecting = start(client.connect())
    await (await transport.accept()).welcome()
    await connecting

    # Say nothing at all: no pings, no messages. The connection goes stale.
    await (await transport.accept()).welcome()


async def test_unconfirmed_subscribe_is_retried(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, subscribe_retry=0.02)
    conn = await welcomed(client, transport)

    subscribing = start(client.subscribe(room()))
    await conn.drop_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing


async def test_server_disconnect_without_reconnect_stops_the_client(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    await conn.push('{"type":"disconnect","reason":"unauthorized","reconnect":false}')

    await transport.refuse_dial()
    assert not client.connected, "client is still connected after being told to go away"

    with pytest.raises(DisconnectError) as raised:
        await client.subscribe(room())
    assert raised.value.reason == REASON_UNAUTHORIZED


async def test_server_disconnect_with_reconnect_dials_again(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    await conn.push('{"type":"disconnect","reason":"server_restart","reconnect":true}')

    await (await transport.accept()).welcome()


async def test_client_offers_every_protocol_and_the_sentinel(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, protocols=[V1JSON(), FakeProtocol("actioncable-v2-json", b"v2:")])

    await welcomed(client, transport)

    assert transport.dialed_with.subprotocols == [
        SUBPROTOCOL_V1_JSON,
        "actioncable-v2-json",
        SUBPROTOCOL_UNSUPPORTED,
    ]


async def test_additional_protocols_are_offered_first(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, additional_protocols=[FakeProtocol("actioncable-v2-json", b"v2:")])

    await welcomed(client, transport)

    assert transport.dialed_with.subprotocols == [
        "actioncable-v2-json",
        SUBPROTOCOL_V1_JSON,
        SUBPROTOCOL_UNSUPPORTED,
    ]


async def test_client_speaks_the_protocol_the_server_picked(transport: FakeTransport, new_client: NewClient) -> None:
    transport.subprotocol = "actioncable-v2-json"
    client = new_client(transport, protocols=[V1JSON(), FakeProtocol("actioncable-v2-json", b"v2:")])

    conn = await welcomed(client, transport)
    start(client.subscribe(room()))

    sent = await conn.sent()
    assert sent.startswith(b"v2:"), f"expected the negotiated protocol to encode the subscribe, got {sent!r}"


async def test_unsupported_sentinel_stops_the_client(transport: FakeTransport, new_client: NewClient) -> None:
    transport.subprotocol = SUBPROTOCOL_UNSUPPORTED
    client = new_client(transport, backoff=FAST)

    with pytest.raises(UnsupportedSubprotocolError):
        await client.connect()

    await transport.accept()
    await transport.refuse_dial()


async def test_no_protocols_stops_the_client(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, protocols=[])

    with pytest.raises(ActionCableError, match="no protocols"):
        await client.connect()

    await transport.refuse_dial()


async def test_unsupported_subprotocol_stops_the_client(transport: FakeTransport, new_client: NewClient) -> None:
    transport.subprotocol = "actioncable-v9-telepathy"
    client = new_client(transport, backoff=FAST)

    with pytest.raises(UnsupportedSubprotocolError):
        await client.connect()

    await transport.accept()
    await transport.refuse_dial()


async def test_subscribe_before_connect(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)

    with pytest.raises(NotConnectedError):
        await client.subscribe(room())


async def test_close_closes_subscriptions(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await client.close()

    await ended(subscription)
    with pytest.raises(NotConnectedError):
        await subscription.perform("speak")


async def test_messages_arrive_on_every_subscription_sharing_an_identifier(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    first = await subscribed(client, conn)
    second = await client.subscribe(room())

    await conn.push(f'{{"identifier":{_quote(ROOM_IDENTIFIER)},"message":{{"body":"Hello!"}}}}')

    for subscription in (first, second):
        assert await receive(subscription) == '{"body":"Hello!"}', "expected the broadcast"

    # Only the last subscription standing tells the server to unsubscribe.
    await first.unsubscribe()
    await conn.expect_no_command()

    await second.unsubscribe()
    await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)


async def test_subscribe_to_a_confirmed_identifier_sends_nothing(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    await subscribed(client, conn)

    # Rails has the identifier already and would ignore a second subscribe, so
    # the one confirmation it gave stands for this subscription too.
    connections: list[bool] = []
    await client.subscribe(room(), on_connected=connections.append)

    await asyncio.sleep(0)
    assert connections == [False], "a subscription joining a confirmed identifier reported itself as a reconnect"
    await conn.expect_no_command()


async def test_subscribers_join_an_in_flight_subscribe(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    first = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    second = start(client.subscribe(room()))
    third = start(client.subscribe(room()))
    await conn.expect_no_command()

    await conn.confirm(ROOM_IDENTIFIER)

    for subscribing in (first, second, third):
        await subscribing


async def test_subscribers_joining_an_in_flight_subscribe_share_its_rejection(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    first = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    second = start(client.subscribe(room()))
    await conn.expect_no_command()

    await conn.reject(ROOM_IDENTIFIER)

    for subscribing in (first, second):
        with pytest.raises(RejectedError):
            await subscribing


async def test_subscribers_joining_an_in_flight_subscribe_follow_it_through_a_reconnect(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    first = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    second = start(client.subscribe(room()))
    await conn.expect_no_command()

    await conn.close()

    reconnected = await transport.accept()
    await reconnected.welcome()
    await reconnected.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await reconnected.expect_no_command()
    await reconnected.confirm(ROOM_IDENTIFIER)

    await first
    await second


async def test_cancelling_the_only_in_flight_subscribe_tells_the_server(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    subscribing = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

    # The server has the subscription whether or not anyone here still wants
    # it, and would ignore the next subscribe for it unless told to let go.
    subscribing.cancel()
    with pytest.raises(asyncio.CancelledError):
        await subscribing
    await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)
    await conn.expect_no_command()

    await subscribed(client, conn)


async def test_cancelling_a_subscriber_joining_an_in_flight_subscribe_leaves_the_first_waiting(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    first = start(client.subscribe(room()))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)

    joining = start(client.subscribe(room()))
    await conn.expect_no_command()

    joining.cancel()
    with pytest.raises(asyncio.CancelledError):
        await joining
    await conn.expect_no_command()

    await conn.confirm(ROOM_IDENTIFIER)
    await first


async def test_connect_after_close_reports_why_it_stopped(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    await welcomed(client, transport)

    await client.close()

    with pytest.raises(ClosedError):
        await client.connect()
    await transport.refuse_dial()


async def test_close_before_connect_leaves_the_client_dead(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)

    await client.close()

    with pytest.raises(ClosedError):
        await client.connect()
    assert not client.connected, "a client closed before it started reports itself connected"
    await transport.refuse_dial()


async def test_close_from_on_disconnected(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    closed = asyncio.Event()

    async def close(_will_reconnect: bool) -> None:
        await client.close()
        closed.set()

    subscribing = start(client.subscribe(room(), on_disconnected=close))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing

    await conn.close()

    try:
        async with asyncio.timeout(2):
            await closed.wait()
    except TimeoutError:
        raise AssertionError("close from on_disconnected never returned") from None


async def test_subscribe_from_on_connected(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    joined: list[asyncio.Task[Any]] = []

    def subscribe_to_other(_reconnected: bool) -> None:
        joined.append(start(client.subscribe(Identifier("OtherChannel"))))

    subscribing = start(client.subscribe(room(), on_connected=subscribe_to_other))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing

    await conn.expect_command(CommandName.SUBSCRIBE, OTHER_IDENTIFIER)
    await conn.confirm(OTHER_IDENTIFIER)
    await joined[0]


async def test_unsubscribe_while_messages_arrive(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, message_buffer=1)
    conn = await welcomed(client, transport)

    for _ in range(50):
        subscription = await subscribed(client, conn)

        pushing = start(conn.push(f'{{"identifier":{_quote(ROOM_IDENTIFIER)},"message":{{"body":"Hello!"}}}}'))

        await subscription.unsubscribe()
        await pushing
        await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)


async def test_first_connection_is_not_a_reconnect(transport: FakeTransport, new_client: NewClient) -> None:
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))
    client = new_client(transport, backoff=FAST)

    connecting = start(client.connect())
    conn = await transport.accept()
    await conn.welcome()
    await connecting

    connections: list[bool] = []
    subscribing = start(client.subscribe(room(), on_connected=connections.append))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing

    await asyncio.sleep(0)
    assert connections == [False], "a first connection that took two dials reported itself as a reconnect"


async def test_perform_before_the_welcome_is_refused(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await conn.close()
    await transport.accept()

    # The connection is up again but not yet welcomed, and the server throws
    # away anything sent that early, so a command then is not a command landed.
    with pytest.raises(NotConnectedError):
        await subscription.perform("speak")


async def test_repeated_confirmation_connects_once(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    connections: list[bool] = []
    subscribing = start(client.subscribe(room(), on_connected=connections.append))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing
    await asyncio.sleep(0)
    assert connections == [False]

    await conn.confirm(ROOM_IDENTIFIER)

    await asyncio.sleep(0.1)
    assert connections == [False], "a second confirmation reported a second connection"


async def test_origin_defaults_to_the_cable_url() -> None:
    urls = {
        "wss://cable.example.com/cable": "https://cable.example.com",
        "ws://cable.example.com:3000/cable": "http://cable.example.com:3000",
        "wss://cable.example.com:8443/cable": "https://cable.example.com:8443",
    }

    # Rails compares Origin against the host it serves on, and turns down a
    # request that carries no Origin at all.
    for url, origin in urls.items():
        transport = FakeTransport()
        client = Client(url, transport=transport)

        connecting = start(client.connect())
        await (await transport.accept()).welcome()
        await connecting

        assert transport.dialed_with.headers["Origin"] == origin, url
        await client.close()


async def test_explicit_origin_wins(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, origin="https://app.example.com")

    connecting = start(client.connect())
    await (await transport.accept()).welcome()
    await connecting

    assert transport.dialed_with.headers["Origin"] == "https://app.example.com"


async def test_header_is_copied(transport: FakeTransport, new_client: NewClient) -> None:
    headers = {"Cookie": "session=secret"}
    client = new_client(transport, headers=headers)

    headers["Cookie"] = "session=tampered"

    connecting = start(client.connect())
    await (await transport.accept()).welcome()
    await connecting

    assert transport.dialed_with.headers["Cookie"] == "session=secret", "expected the header as it was given"


async def test_every_dial_asks_for_the_header_again(transport: FakeTransport, new_client: NewClient) -> None:
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))

    dials = 0

    def authorization() -> dict[str, str]:
        nonlocal dials
        dials += 1

        return {"Authorization": f"Bearer token-{dials}"}

    client = new_client(
        transport,
        backoff=FAST,
        headers={"Origin": "https://app.example.com"},
        headers_func=authorization,
    )

    connecting = start(client.connect())
    await (await transport.accept()).welcome()
    await connecting

    dialed = transport.dialed_with.headers
    assert dialed["Authorization"] == "Bearer token-2", "expected the redial to carry the credentials it asked for"
    assert dialed["Origin"] == "https://app.example.com", "expected the headers set once to survive"


async def test_a_terminal_dial_error_stops_the_initial_connection(
    transport: FakeTransport, new_client: NewClient
) -> None:
    denied = ConnectionRefusedError("connection denied")
    transport.fail_next_dial(denied)
    client = new_client(transport, backoff=FAST, stop_on_error=lambda error: error is denied)

    with pytest.raises(ConnectionRefusedError) as raised:
        await client.connect()
    assert raised.value is denied
    assert client.error is denied
    await transport.refuse_dial()


async def test_a_non_terminal_connection_error_still_reconnects(
    transport: FakeTransport, new_client: NewClient
) -> None:
    signed_out = RuntimeError("sign in again")
    client = new_client(transport, backoff=FAST, stop_on_error=lambda error: error is signed_out)
    conn = await welcomed(client, transport)

    await conn.close()
    await (await transport.accept()).welcome()

    assert client.error is None, "a retryable error stopped the client"


async def test_a_terminal_connection_error_stops_subscriptions(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(
        transport,
        backoff=FAST,
        stop_on_error=lambda error: isinstance(error, ConnectionResetError),
    )
    conn = await welcomed(client, transport)

    disconnections: asyncio.Queue[bool] = asyncio.Queue()
    subscribing = start(client.subscribe(room(), on_disconnected=disconnections.put_nowait))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    subscription = await subscribing

    await conn.close()

    assert not await disconnections.get(), "on_disconnected promised a reconnect after a terminal error"
    await stopped(client)
    assert isinstance(client.error, ConnectionResetError)
    await ended(subscription)
    assert isinstance(subscription.error, ConnectionResetError)
    await transport.refuse_dial()


async def test_a_terminal_header_error_stops_the_initial_connection(
    transport: FakeTransport, new_client: NewClient
) -> None:
    signed_out = RuntimeError("sign in again")

    def refuse() -> dict[str, str]:
        raise signed_out

    client = new_client(
        transport,
        backoff=FAST,
        stop_on_error=lambda error: error is signed_out,
        headers_func=refuse,
    )

    with pytest.raises(RuntimeError) as raised:
        await client.connect()
    assert raised.value is signed_out
    assert client.error is signed_out
    await transport.refuse_dial()


async def test_a_terminal_header_error_stops_a_reconnect(transport: FakeTransport, new_client: NewClient) -> None:
    signed_out = RuntimeError("sign in again")
    headers = 0

    def authorization() -> dict[str, str]:
        nonlocal headers
        headers += 1
        if headers == 1:
            return {"Authorization": "Bearer token"}
        raise signed_out

    client = new_client(
        transport,
        backoff=FAST,
        stop_on_error=lambda error: error is signed_out,
        headers_func=authorization,
    )

    conn = await welcomed(client, transport)
    await conn.close()

    await stopped(client)
    assert client.error is signed_out
    assert headers == 2, "expected one initial header and one failed reconnect header"
    await transport.refuse_dial()


async def test_a_dial_is_turned_down_when_the_header_cannot_be_built(
    transport: FakeTransport, new_client: NewClient
) -> None:
    asked = 0

    def authorization() -> dict[str, str]:
        nonlocal asked
        asked += 1
        if asked == 1:
            raise RuntimeError("no credentials to hand over")

        return {"Authorization": "Bearer token"}

    client = new_client(transport, backoff=FAST, headers_func=authorization)

    connecting = start(client.connect())
    await (await transport.accept()).welcome()
    await connecting

    assert transport.dialed_with.headers["Authorization"] == "Bearer token", (
        "expected the client to dial again after the header failed"
    )


async def test_an_unsubscribe_during_a_resubscribe_goes_out_after_it(new_client: NewClient) -> None:
    transport = FakeTransport(write_buffer=0)
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)

    await subscribed(client, conn)
    subscribing = start(client.subscribe(Identifier("OtherChannel")))
    await conn.expect_command(CommandName.SUBSCRIBE, OTHER_IDENTIFIER)
    await conn.confirm(OTHER_IDENTIFIER)
    other = await subscribing

    await conn.close()

    # The welcome sets the client resubscribing both. With nobody reading yet
    # it is stuck mid-list on the first write, which is when the unsubscribe
    # arrives and queues up behind it. Had it slipped in ahead of the second
    # subscribe, the server would have been left holding OtherChannel with no
    # one here to answer for it.
    reconnected = await transport.accept()
    await reconnected.welcome()
    await reconnected.writing.get()
    unsubscribing = start(other.unsubscribe())
    await asyncio.sleep(0.02)

    first = await reconnected.command()
    second = await reconnected.command()
    assert [first.name, second.name] == [CommandName.SUBSCRIBE, CommandName.SUBSCRIBE], (
        "expected both resubscribes before anything else"
    )
    assert sorted([first.identifier, second.identifier]) == sorted([ROOM_IDENTIFIER, OTHER_IDENTIFIER])
    await reconnected.expect_command(CommandName.UNSUBSCRIBE, OTHER_IDENTIFIER)
    await unsubscribing


async def test_a_connect_that_runs_out_of_time_stops_the_client(
    transport: FakeTransport, new_client: NewClient
) -> None:
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))
    client = new_client(transport, backoff=(3600, 3600))

    with pytest.raises(TimeoutError) as raised:
        await client.connect(timeout=0.05)
    assert "connection refused" in str(raised.value), "expected the error to say what the client was waiting out"

    await stopped(client)
    assert isinstance(client.error, TimeoutError)
    with pytest.raises(TimeoutError):
        await client.connect()
    await transport.refuse_dial()


async def test_a_connect_that_runs_out_of_time_names_the_header_that_failed(
    transport: FakeTransport, new_client: NewClient
) -> None:
    no_credentials = RuntimeError("no credentials to hand over")

    def refuse() -> dict[str, str]:
        raise no_credentials

    client = new_client(transport, backoff=FAST, headers_func=refuse)

    with pytest.raises(TimeoutError) as raised:
        await client.connect(timeout=0.05)
    assert raised.value.__cause__ is no_credentials, "expected the header error to be the cause"
    assert "no credentials to hand over" in str(raised.value)
    await transport.refuse_dial()


async def test_max_attempts_stops_the_client(transport: FakeTransport, new_client: NewClient) -> None:
    refused = ConnectionRefusedError("connection refused")
    transport.fail_next_dial(refused)
    transport.fail_next_dial(refused)
    client = new_client(transport, backoff=FAST, max_attempts=2)

    with pytest.raises(GaveUpError) as raised:
        await client.connect()
    assert raised.value.__cause__ is refused, "expected the last attempt's error to be the cause"

    await stopped(client)
    assert isinstance(client.error, GaveUpError)
    await transport.refuse_dial()


async def test_a_welcome_resets_the_attempt_count(transport: FakeTransport, new_client: NewClient) -> None:
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))
    client = new_client(transport, backoff=FAST, max_attempts=3)
    conn = await welcomed(client, transport)

    # Losing the connection is the first failed attempt of the outage, and the
    # refused redial the second. Had the failure before the welcome still
    # counted, that would have been the third.
    transport.fail_next_dial(ConnectionRefusedError("connection refused"))
    await conn.close()

    await (await transport.accept()).welcome()
    assert client.error is None, "a failure before the welcome should not count against the outage after it"


async def test_giving_up_tells_subscriptions_the_client_is_not_coming_back(
    transport: FakeTransport, new_client: NewClient
) -> None:
    client = new_client(transport, backoff=FAST, max_attempts=1)
    conn = await welcomed(client, transport)

    disconnections: asyncio.Queue[bool] = asyncio.Queue()
    subscribing = start(client.subscribe(room(), on_disconnected=disconnections.put_nowait))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    await subscribing

    # Losing the connection is the only attempt allowed, so the client is done
    # for, and the subscription should hear that rather than a promise to
    # return.
    await conn.close()

    assert not await disconnections.get(), "on_disconnected promised a reconnect the client was about to give up on"
    await stopped(client)
    assert isinstance(client.error, GaveUpError)
    await transport.refuse_dial()


async def test_done_and_error_follow_the_client(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)

    assert client.error is None, "a client that hasn't started has nothing to report"
    conn = await welcomed(client, transport)
    assert client.error is None, "a running client has nothing to report"
    await still_running(start(client.done()))

    await conn.push('{"type":"disconnect","reason":"unauthorized","reconnect":false}')

    await stopped(client)
    assert isinstance(client.error, DisconnectError)
    assert client.error.reason == REASON_UNAUTHORIZED


async def test_messages_close_after_the_last_callback_returns(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    entered = asyncio.Event()
    release = asyncio.Event()

    async def hold(_will_reconnect: bool) -> None:
        entered.set()
        await release.wait()

    subscribing = start(client.subscribe(room(), on_disconnected=hold))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    subscription = await subscribing

    await client.close()
    await entered.wait()

    reading = start(anext(aiter(subscription)))
    await still_running(reading, quiet=0.1)

    release.set()

    with pytest.raises(StopAsyncIteration):
        await reading
    assert isinstance(subscription.error, ClosedError)


async def test_unsubscribed_subscription_reports_why(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    assert subscription.error is None, "a live subscription has nothing to report"

    await subscription.unsubscribe()
    await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)

    assert isinstance(subscription.error, UnsubscribedError)


async def test_rejection_after_a_reconnect_reports_why(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport, backoff=FAST)
    conn = await welcomed(client, transport)
    subscription = await subscribed(client, conn)

    await conn.close()

    reconnected = await transport.accept()
    await reconnected.welcome()
    await reconnected.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await reconnected.push(f'{{"type":"reject_subscription","identifier":{_quote(ROOM_IDENTIFIER)}}}')

    await ended(subscription)
    assert isinstance(subscription.error, RejectedError)


async def test_unsubscribe_needs_no_deadline(transport: FakeTransport, new_client: NewClient) -> None:
    client = new_client(transport)
    conn = await welcomed(client, transport)

    subscribing = start(client.subscribe(room(), timeout=5))
    await conn.expect_command(CommandName.SUBSCRIBE, ROOM_IDENTIFIER)
    await conn.confirm(ROOM_IDENTIFIER)
    subscription = await subscribing

    # The deadline the subscription was made under is long gone by the time
    # the caller is tearing down, and that must not stop the hang-up from
    # going out.
    await asyncio.sleep(0.01)

    await subscription.unsubscribe()
    await conn.expect_command(CommandName.UNSUBSCRIBE, ROOM_IDENTIFIER)


def _quote(value: str) -> str:
    return json.dumps(value)
