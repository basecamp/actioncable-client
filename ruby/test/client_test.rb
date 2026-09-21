# frozen_string_literal: true

require "test_helper"

class ClientTest < CableTest
  Identifier = ActionCableClient::Identifier
  Protocol = ActionCableClient::Protocol

  def test_connect_waits_for_the_welcome
    transport = fake_transport
    client = test_client(transport)

    connected = connecting(client)
    connection = transport.accept

    assert connected.pending?(0.05), "connect returned before the welcome"

    connection.welcome
    connected.value

    assert client.connected?, "client is not connected after the welcome"
  end

  def test_connect_retries_until_the_server_answers
    transport = fake_transport
    transport.fail_next_dial(StandardError.new("connection refused"))
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)

    connected = connecting(client)
    transport.accept.welcome

    connected.value
  end

  def test_subscribe_receives_messages
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    connections = Queue.new
    pending = subscribing(client, on_connected: ->(reconnected) { connections.push(reconnected) })

    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    subscription = pending.value

    assert_equal false, connections.pop, "the first connection reported itself as a reconnect"

    connection.broadcast(ROOM, { body: "Hello!" })

    assert_equal "Hello!", subscription.next_message(timeout: WAIT).parse["body"]
  end

  def test_subscribe_rejected
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    rejections = Queue.new
    pending = subscribing(client, on_rejected: -> { rejections.push(true) })

    assert_command connection, "subscribe", ROOM
    connection.reject(ROOM)

    assert_kind_of ActionCableClient::RejectedError, pending.error
    assert rejections.pop(timeout: WAIT), "on_rejected was never called"
  end

  def test_perform_sends_an_action
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    subscription.perform("speak", body: "Hello!")

    command = assert_command(connection, "message", ROOM)
    assert_equal %({"action":"speak","body":"Hello!"}), command["data"], "expected the action alongside the data"
  end

  def test_send_delivers_data_without_an_action
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    subscription.send_data(body: "Hello!")

    command = assert_command(connection, "message", ROOM)
    assert_equal %({"body":"Hello!"}), command["data"], "expected the data on its own"
  end

  def test_send_refuses_data_that_cannot_encode
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    assert_raises(ActionCableClient::Error) { subscription.send_data(body: Float::NAN) }
  end

  def test_perform_refuses_data_that_is_not_an_object
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    assert_raises(ActionCableClient::Error) { subscription.perform("speak", [ "nope" ]) }
  end

  def test_unsubscribe_closes_messages_and_tells_the_server
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    assert subscription.unsubscribe, "unsubscribe should have told the server"
    assert_command connection, "unsubscribe", ROOM

    assert_nil subscription.next_message(timeout: WAIT), "messages are still delivering after unsubscribe"
  end

  def test_reconnect_resubscribes
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    connections, disconnections = Queue.new, Queue.new
    pending = subscribing(client,
      on_connected: ->(reconnected) { connections.push(reconnected) },
      on_disconnected: ->(will_reconnect) { disconnections.push(will_reconnect) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value
    connections.pop

    connection.close

    assert_equal true, disconnections.pop(timeout: WAIT), "the disconnect said the client would not come back"

    reconnected = transport.accept
    reconnected.welcome
    assert_command reconnected, "subscribe", ROOM
    reconnected.confirm(ROOM)

    assert_equal true, connections.pop(timeout: WAIT), "the confirmation after a reconnect should say so"
  end

  def test_stale_connection_is_replaced
    transport = fake_transport
    client = test_client(transport, stale_after: 0.075, initial_backoff: 0.001, longest_backoff: 0.001)

    connected = connecting(client)
    transport.accept.welcome
    connected.value

    # Say nothing at all: no pings, no messages. The connection goes stale.
    transport.accept.welcome
  end

  def test_unconfirmed_subscribe_is_retried
    transport = fake_transport
    client = test_client(transport, subscribe_retry: 0.02)
    connection = welcomed(client, transport)

    pending = subscribing(client)
    connection.drop_command
    assert_command connection, "subscribe", ROOM

    connection.confirm(ROOM)
    pending.value
  end

  def test_server_disconnect_without_reconnect_stops_the_client
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    connection.disconnect("unauthorized", reconnect: false)

    assert transport.refuse_dial, "the client dialed again after being told to go away"
    assert_equal false, client.connected?, "the client is still connected after being told to go away"

    error = assert_raises(ActionCableClient::DisconnectError) { client.subscribe(room) }
    assert_equal Protocol::Reasons::UNAUTHORIZED, error.reason
  end

  def test_server_disconnect_with_reconnect_dials_again
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    connection.disconnect("server_restart", reconnect: true)

    transport.accept.welcome
  end

  def test_client_offers_every_protocol_and_the_sentinel
    transport = fake_transport
    client = test_client(transport, protocols: [ Protocol::V1JSON.new, StampedProtocol.new("actioncable-v2-json") ])

    welcomed(client, transport)

    assert_equal [ Protocol::V1JSON::SUBPROTOCOL, "actioncable-v2-json", Protocol::UNSUPPORTED ],
      transport.dialed_with[:subprotocols]
  end

  def test_additional_protocols_are_offered_first
    transport = fake_transport
    client = test_client(transport, additional_protocols: [ StampedProtocol.new("actioncable-v2-json") ])

    welcomed(client, transport)

    assert_equal [ "actioncable-v2-json", Protocol::V1JSON::SUBPROTOCOL, Protocol::UNSUPPORTED ],
      transport.dialed_with[:subprotocols]
  end

  def test_client_speaks_the_protocol_the_server_picked
    transport = fake_transport
    transport.subprotocol = "actioncable-v2-json"
    client = test_client(transport,
      protocols: [ Protocol::V1JSON.new, StampedProtocol.new("actioncable-v2-json") ])

    connection = welcomed(client, transport)
    subscribing(client)

    sent = connection.sent
    assert sent.start_with?("v2:"), "expected the negotiated protocol to encode the subscribe, got #{sent}"
  end

  def test_unsupported_sentinel_stops_the_client
    transport = fake_transport
    transport.subprotocol = Protocol::UNSUPPORTED
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)

    assert_raises(ActionCableClient::UnsupportedSubprotocolError) { client.connect }

    transport.accept
    assert transport.refuse_dial, "the client dialed again after a subprotocol it can't speak"
  end

  def test_no_protocols_stops_the_client
    transport = fake_transport
    client = test_client(transport, protocols: [])

    assert_raises(ActionCableClient::NoProtocolsError) { client.connect }
    assert transport.refuse_dial, "the client dialed with nothing to offer"
  end

  def test_unsupported_subprotocol_stops_the_client
    transport = fake_transport
    transport.subprotocol = "actioncable-v9-telepathy"
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)

    assert_raises(ActionCableClient::UnsupportedSubprotocolError) { client.connect }

    transport.accept
    assert transport.refuse_dial, "the client dialed again after a subprotocol it can't speak"
  end

  def test_subscribe_before_connect
    client = test_client(fake_transport)

    assert_raises(ActionCableClient::NotConnectedError) { client.subscribe(room) }
  end

  def test_close_closes_subscriptions
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    client.close

    assert_nil subscription.next_message(timeout: WAIT), "messages are still delivering after close"
    assert_raises(ActionCableClient::NotConnectedError) { subscription.perform("speak") }
  end

  def test_messages_arrive_on_every_subscription_sharing_an_identifier
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    first = subscribed(client, connection)
    second = client.subscribe(room)

    connection.broadcast(ROOM, { body: "Hello!" })

    [ first, second ].each do |subscription|
      assert_equal %({"body":"Hello!"}), subscription.next_message(timeout: WAIT).to_s
    end

    # Only the last subscription standing tells the server to unsubscribe.
    assert_equal false, first.unsubscribe, "the first of two told the server"
    assert connection.quiet?

    assert_equal true, second.unsubscribe, "the last one standing should have told the server"
    assert_command connection, "unsubscribe", ROOM
  end

  def test_subscribe_to_a_confirmed_identifier_sends_nothing
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscribed(client, connection)

    # Rails has the identifier already and would ignore a second subscribe, so
    # the one confirmation it gave stands for this subscription too.
    connections = Queue.new
    client.subscribe(room, on_connected: ->(reconnected) { connections.push(reconnected) })

    assert_equal false, connections.pop(timeout: WAIT), "joining a confirmed identifier reported a reconnect"
    assert connection.quiet?
  end

  def test_subscribers_join_an_in_flight_subscribe
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    first = subscribing(client)
    assert_command connection, "subscribe", ROOM
    second, third = subscribing(client), subscribing(client)
    assert connection.quiet?

    connection.confirm(ROOM)

    [ first, second, third ].each(&:value)
  end

  def test_subscribers_joining_an_in_flight_subscribe_share_its_rejection
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    first = subscribing(client)
    assert_command connection, "subscribe", ROOM
    second = subscribing(client)
    assert connection.quiet?

    connection.reject(ROOM)

    assert_kind_of ActionCableClient::RejectedError, first.error
    assert_kind_of ActionCableClient::RejectedError, second.error
  end

  def test_subscribers_joining_an_in_flight_subscribe_follow_it_through_a_reconnect
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    first = subscribing(client)
    assert_command connection, "subscribe", ROOM
    second = subscribing(client)
    assert connection.quiet?

    connection.close

    reconnected = transport.accept
    reconnected.welcome
    assert_command reconnected, "subscribe", ROOM
    assert reconnected.quiet?
    reconnected.confirm(ROOM)

    first.value
    second.value
  end

  def test_cancelling_the_only_in_flight_subscribe_tells_the_server
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    pending = subscribing(client, timeout: 0.05)
    assert_command connection, "subscribe", ROOM

    # The server has the subscription whether or not anyone here still wants
    # it, and would ignore the next subscribe for it unless told to let go.
    assert_kind_of ActionCableClient::TimeoutError, pending.error
    assert_command connection, "unsubscribe", ROOM
    assert connection.quiet?

    subscribed(client, connection)
  end

  def test_cancelling_a_subscriber_joining_an_in_flight_subscribe_leaves_the_first_waiting
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    first = subscribing(client)
    assert_command connection, "subscribe", ROOM

    joining = subscribing(client, timeout: 0.05)
    assert connection.quiet?

    assert_kind_of ActionCableClient::TimeoutError, joining.error
    assert connection.quiet?

    connection.confirm(ROOM)
    first.value
  end

  def test_connect_after_close_reports_why_it_stopped
    transport = fake_transport
    client = test_client(transport)
    welcomed(client, transport)

    client.close

    assert_raises(ActionCableClient::ClosedError) { client.connect }
    assert transport.refuse_dial, "a closed client dialed again"
  end

  def test_close_before_connect_leaves_the_client_dead
    transport = fake_transport
    client = test_client(transport)

    client.close

    assert_raises(ActionCableClient::ClosedError) { client.connect }
    assert_equal false, client.connected?, "a client closed before it started reports itself connected"
    assert transport.refuse_dial, "a closed client dialed"
  end

  def test_close_from_on_disconnected
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    closing = Queue.new
    pending = subscribing(client, on_disconnected: ->(_) { closing.push(client.close) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value

    connection.close

    assert closing.pop(timeout: WAIT), "close from on_disconnected never returned"
  end

  def test_subscribe_from_on_connected
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    joining = Queue.new
    pending = subscribing(client, on_connected: lambda do |_|
      Thread.new { joining.push(client.subscribe(Identifier.new("OtherChannel"))) }
    end)
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value

    assert_command connection, "subscribe", OTHER
    connection.confirm(OTHER)

    assert joining.pop(timeout: WAIT), "the subscribe from on_connected never came back"
  end

  def test_unsubscribe_while_messages_arrive
    transport = fake_transport
    client = test_client(transport, message_buffer: 1)
    connection = welcomed(client, transport)

    50.times do
      subscription = subscribed(client, connection)

      pushing = Future.new { connection.broadcast(ROOM, { body: "Hello!" }) }
      subscription.unsubscribe
      pushing.value
      assert_command connection, "unsubscribe", ROOM
    end
  end

  def test_first_connection_is_not_a_reconnect
    transport = fake_transport
    transport.fail_next_dial(StandardError.new("connection refused"))
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)

    connected = connecting(client)
    connection = transport.accept
    connection.welcome
    connected.value

    connections = Queue.new
    pending = subscribing(client, on_connected: ->(reconnected) { connections.push(reconnected) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value

    assert_equal false, connections.pop(timeout: WAIT), "a first connection that took two dials said reconnected"
  end

  def test_perform_before_the_welcome_is_refused
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    connection.close
    transport.accept

    # The connection is up again but not yet welcomed, and the server throws
    # away anything sent that early, so a command then is not a command landed.
    assert_raises(ActionCableClient::NotConnectedError) { subscription.perform("speak") }
  end

  def test_repeated_confirmation_connects_once
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    connections = Queue.new
    pending = subscribing(client, on_connected: ->(reconnected) { connections.push(reconnected) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value
    connections.pop

    connection.confirm(ROOM)

    assert_nil connections.pop(timeout: 0.1), "a second confirmation reported a second connection"
  end

  def test_origin_defaults_to_the_cable_url
    # Rails compares Origin against the host it serves on, and turns down a
    # request that carries no Origin at all.
    {
      "wss://cable.example.com/cable" => "https://cable.example.com",
      "ws://cable.example.com:3000/cable" => "http://cable.example.com:3000",
      "wss://cable.example.com:8443/cable" => "https://cable.example.com:8443"
    }.each do |url, origin|
      transport = fake_transport
      client = ActionCableClient.new(url, transport: transport, logger: test_logger)
      (@clients ||= []) << client

      connected = connecting(client)
      transport.accept.welcome
      connected.value

      assert_equal origin, transport.dialed_with[:headers]["Origin"], url
    end
  end

  def test_explicit_origin_wins
    transport = fake_transport
    client = test_client(transport, origin: "https://app.example.com")

    connected = connecting(client)
    transport.accept.welcome
    connected.value

    assert_equal "https://app.example.com", transport.dialed_with[:headers]["Origin"]
  end

  def test_header_is_copied
    transport = fake_transport
    header = { "Cookie" => "session=secret" }
    client = test_client(transport, header: header)

    header["Cookie"] = "session=tampered"

    connected = connecting(client)
    transport.accept.welcome
    connected.value

    assert_equal "session=secret", transport.dialed_with[:headers]["Cookie"], "expected the header as it was given"
  end

  def test_every_dial_asks_for_the_header_again
    transport = fake_transport
    transport.fail_next_dial(StandardError.new("connection refused"))

    dials = 0
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      header: { "Origin" => "https://app.example.com" },
      header_provider: -> { { "Authorization" => "Bearer token-#{dials += 1}" } })

    connected = connecting(client)
    transport.accept.welcome
    connected.value

    dialed = transport.dialed_with[:headers]
    assert_equal "Bearer token-2", dialed["Authorization"], "the redial should carry the credentials it asked for"
    assert_equal "https://app.example.com", dialed["Origin"], "the headers set once should survive"
  end

  def test_a_terminal_dial_error_stops_the_initial_connection
    transport = fake_transport
    denied = StandardError.new("connection denied")
    transport.fail_next_dial(denied)
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      stop_on_error: ->(error) { error.equal?(denied) })

    assert_same denied, assert_raises(StandardError) { client.connect }
    assert_same denied, client.error
    assert transport.refuse_dial, "the client dialed again after a terminal error"
  end

  def test_a_non_terminal_connection_error_still_reconnects
    transport = fake_transport
    signed_out = StandardError.new("sign in again")
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      stop_on_error: ->(error) { error.equal?(signed_out) })
    connection = welcomed(client, transport)

    connection.close
    transport.accept.welcome

    assert_nil client.error, "a retryable error stopped the client"
  end

  def test_a_terminal_connection_error_stops_subscriptions
    transport = fake_transport
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      stop_on_error: ->(error) { error.is_a?(ActionCableClient::Error) })
    connection = welcomed(client, transport)

    disconnections = Queue.new
    pending = subscribing(client, on_disconnected: ->(will_reconnect) { disconnections.push(will_reconnect) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    subscription = pending.value

    connection.close

    assert_equal false, disconnections.pop(timeout: WAIT), "on_disconnected promised a reconnect"
    assert client.wait(timeout: WAIT), "the client kept reconnecting after the terminal error"
    assert_kind_of ActionCableClient::Error, client.error
    assert_nil subscription.next_message(timeout: WAIT), "the subscription stayed open after the client stopped"
    assert_same client.error, subscription.error
    assert transport.refuse_dial, "the client dialed again after a terminal error"
  end

  def test_a_terminal_header_error_stops_the_initial_connection
    transport = fake_transport
    signed_out = StandardError.new("sign in again")
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      stop_on_error: ->(error) { error.equal?(signed_out) },
      header_provider: -> { raise signed_out })

    assert_same signed_out, assert_raises(StandardError) { client.connect }
    assert_same signed_out, client.error
    assert transport.refuse_dial, "the client dialed after a terminal header error"
  end

  def test_a_terminal_header_error_stops_a_reconnect
    transport = fake_transport
    signed_out = StandardError.new("sign in again")
    headers = 0
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      stop_on_error: ->(error) { error.equal?(signed_out) },
      header_provider: lambda do
        headers += 1
        raise signed_out unless headers == 1

        { "Authorization" => "Bearer token" }
      end)

    connection = welcomed(client, transport)
    connection.close

    assert client.wait(timeout: WAIT), "the client kept reconnecting after the terminal header error"
    assert_same signed_out, client.error
    assert_equal 2, headers, "expected one initial header and one failed reconnect header"
    assert transport.refuse_dial, "the client dialed after a terminal header error"
  end

  def test_a_dial_is_turned_down_when_the_header_cannot_be_built
    transport = fake_transport

    asked = 0
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      header_provider: lambda do
        asked += 1
        raise StandardError, "no credentials to hand over" if asked == 1

        { "Authorization" => "Bearer token" }
      end)

    connected = connecting(client)
    transport.accept.welcome
    connected.value

    assert_equal "Bearer token", transport.dialed_with[:headers]["Authorization"],
      "the client should have dialed again after the header failed"
  end

  def test_an_unsubscribe_during_a_resubscribe_goes_out_after_it
    transport = fake_transport
    transport.write_buffer = 0
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)

    subscribed(client, connection)
    pending = subscribing(client, Identifier.new("OtherChannel"))
    assert_command connection, "subscribe", OTHER
    connection.confirm(OTHER)
    other = pending.value

    connection.close

    # The welcome sets the client resubscribing both. With nobody reading yet
    # it is stuck mid-list on the first write, which is when the unsubscribe
    # arrives and queues up behind it. Had it slipped in ahead of the second
    # subscribe, the server would have been left holding OtherChannel with no
    # one here to answer for it.
    reconnected = transport.accept
    reconnected.welcome
    reconnected.writing
    unsubscribing = Future.new { other.unsubscribe }
    sleep 0.02

    first, second = reconnected.command, reconnected.command
    assert_equal %w[subscribe subscribe], [ first["command"], second["command"] ],
      "expected both resubscribes before anything else"
    assert_equal [ OTHER, ROOM ].sort, [ first["identifier"], second["identifier"] ].sort
    assert_command reconnected, "unsubscribe", OTHER
    assert unsubscribing.value, "unsubscribe should have told the server"
  end

  def test_a_connect_that_runs_out_of_time_stops_the_client
    transport = fake_transport
    transport.fail_next_dial(StandardError.new("connection refused"))
    client = test_client(transport, initial_backoff: 3600, longest_backoff: 3600)

    error = assert_raises(ActionCableClient::TimeoutError) { client.connect(timeout: 0.05) }
    assert_includes error.message, "connection refused", "the error should say what the client was waiting out"

    assert client.wait(timeout: WAIT), "the client kept running after connect gave up"
    assert_kind_of ActionCableClient::TimeoutError, client.error
    assert_raises(ActionCableClient::TimeoutError) { client.connect }
    assert transport.refuse_dial, "the client dialed again after giving up"
  end

  def test_a_connect_that_runs_out_of_time_names_the_header_that_failed
    transport = fake_transport
    no_credentials = StandardError.new("no credentials to hand over")
    client = test_client(transport,
      initial_backoff: 0.001, longest_backoff: 0.001,
      header_provider: -> { raise no_credentials })

    error = assert_raises(ActionCableClient::TimeoutError) { client.connect(timeout: 0.05) }

    assert_same no_credentials, error.last_error, "the header error should be carried rather than hidden"
    assert transport.refuse_dial, "the client dialed again after giving up"
  end

  def test_max_attempts_stops_the_client
    transport = fake_transport
    refused = StandardError.new("connection refused")
    2.times { transport.fail_next_dial(refused) }
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001, max_attempts: 2)

    error = assert_raises(ActionCableClient::GaveUpError) { client.connect }
    assert_same refused, error.last_error, "the last attempt's error should be carried"

    assert client.wait(timeout: WAIT), "the client kept running after its attempts ran out"
    assert_kind_of ActionCableClient::GaveUpError, client.error
    assert transport.refuse_dial, "the client dialed again after giving up"
  end

  def test_a_welcome_resets_the_attempt_count
    transport = fake_transport
    transport.fail_next_dial(StandardError.new("connection refused"))
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001, max_attempts: 3)
    connection = welcomed(client, transport)

    # Losing the connection is the first failed attempt of the outage, and the
    # refused redial the second. Had the failure before the welcome still
    # counted, that would have been the third.
    transport.fail_next_dial(StandardError.new("connection refused"))
    connection.close

    transport.accept.welcome

    assert_nil client.error, "a failure before the welcome should not count against the outage after it"
  end

  def test_giving_up_tells_subscriptions_the_client_is_not_coming_back
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001, max_attempts: 1)
    connection = welcomed(client, transport)

    disconnections = Queue.new
    pending = subscribing(client, on_disconnected: ->(will_reconnect) { disconnections.push(will_reconnect) })
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    pending.value

    # Losing the connection is the only attempt allowed, so the client is done
    # for, and the subscription should hear that rather than a promise to come
    # back.
    connection.close

    assert_equal false, disconnections.pop(timeout: WAIT), "on_disconnected promised a reconnect"
    assert client.wait(timeout: WAIT), "the client kept running after its attempts ran out"
    assert_kind_of ActionCableClient::GaveUpError, client.error
    assert transport.refuse_dial, "the client dialed again after giving up"
  end

  def test_wait_and_error_follow_the_client
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)

    assert_nil client.error, "a client that hasn't started has nothing to report"
    connection = welcomed(client, transport)
    assert_nil client.error, "a running client has nothing to report"
    assert_equal false, client.wait(timeout: 0), "wait answered on a running client"

    connection.disconnect("unauthorized", reconnect: false)

    assert client.wait(timeout: WAIT), "wait never answered after the server hung up for good"
    assert_kind_of ActionCableClient::DisconnectError, client.error
    assert_equal Protocol::Reasons::UNAUTHORIZED, client.error.reason
  end

  def test_messages_close_after_the_last_callback_returns
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    entered, release = Queue.new, Queue.new
    pending = subscribing(client, on_disconnected: lambda do |_|
      entered.push(true)
      release.pop
    end)
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    subscription = pending.value

    closing = Future.new { client.close }
    entered.pop

    assert_raises(ActionCableClient::TimeoutError, "messages ended while a callback was still running") do
      subscription.next_message(timeout: 0.1)
    end

    release.push(true)
    closing.value

    assert_nil subscription.next_message(timeout: WAIT), "messages are still delivering after the last callback"
    assert_kind_of ActionCableClient::ClosedError, subscription.error
  end

  def test_unsubscribed_subscription_reports_why
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    assert_nil subscription.error, "a live subscription has nothing to report"

    subscription.unsubscribe
    assert_command connection, "unsubscribe", ROOM

    assert_kind_of ActionCableClient::UnsubscribedError, subscription.error
  end

  def test_rejection_after_a_reconnect_reports_why
    transport = fake_transport
    client = test_client(transport, initial_backoff: 0.001, longest_backoff: 0.001)
    connection = welcomed(client, transport)
    subscription = subscribed(client, connection)

    connection.close

    reconnected = transport.accept
    reconnected.welcome
    assert_command reconnected, "subscribe", ROOM
    reconnected.reject(ROOM)

    assert_nil subscription.next_message(timeout: WAIT), "messages are still delivering after a rejection"
    assert_kind_of ActionCableClient::RejectedError, subscription.error
  end

  def test_unsubscribe_needs_no_timeout
    transport = fake_transport
    client = test_client(transport)
    connection = welcomed(client, transport)

    pending = subscribing(client, timeout: WAIT)
    assert_command connection, "subscribe", ROOM
    connection.confirm(ROOM)
    subscription = pending.value

    # The timeout the subscription was made under is long gone by the time the
    # caller is tearing down, and that must not stop the hang-up going out.
    assert subscription.unsubscribe, "unsubscribe should have told the server"
    assert_command connection, "unsubscribe", ROOM
  end

  # Speaks a made-up subprotocol and stamps everything it encodes, so a test
  # can tell which protocol the client settled on.
  class StampedProtocol
    def initialize(subprotocol)
      @subprotocol = subprotocol
      @stamp = "v2:"
      @v1 = Protocol::V1JSON.new
    end

    attr_reader :subprotocol

    def encode(command)
      @stamp + @v1.encode(command)
    end

    def decode(payload)
      @v1.decode(payload.delete_prefix(@stamp))
    end
  end
end
