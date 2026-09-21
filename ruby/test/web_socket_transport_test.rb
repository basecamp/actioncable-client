# frozen_string_literal: true

require "test_helper"

class WebSocketTransportTest < CableTest
  Opcode = ActionCableClient::WebSocketTransport::Opcode
  Protocol = ActionCableClient::Protocol

  def test_web_socket_transport_negotiates_the_subprotocol
    server = loopback_server
    connection = dial(server, subprotocols: [ Protocol::V1JSON::SUBPROTOCOL ])

    assert_equal Protocol::V1JSON::SUBPROTOCOL, connection.subprotocol
    assert_equal Protocol::V1JSON::SUBPROTOCOL, server.accept.header("Sec-WebSocket-Protocol"),
      "expected the client to offer the subprotocol"
  end

  def test_web_socket_transport_sends_headers
    server = loopback_server
    dial(server, subprotocols: [ Protocol::V1JSON::SUBPROTOCOL ],
      headers: { "Cookie" => "session=secret", "Origin" => "https://example.com" })

    peer = server.accept
    assert_equal "session=secret", peer.header("Cookie")
    assert_equal "https://example.com", peer.header("Origin")
    assert_equal ActionCableClient::WebSocketTransport::USER_AGENT, peer.header("User-Agent")
    assert_equal "/cable", peer.request.target
  end

  def test_web_socket_transport_sends_the_callers_user_agent
    server = loopback_server
    dial(server, headers: { "User-Agent" => "custom-agent" })

    assert_equal "custom-agent", server.accept.header("User-Agent")
  end

  def test_web_socket_transport_neutralizes_header_injection
    server = loopback_server
    dial(server, headers: { "Authorization" => "Bearer token\r\nX-Injected: gotcha" })

    peer = server.accept
    assert_nil peer.header("X-Injected"), "expected the newlines to be neutralized"
    assert peer.header("Authorization").start_with?("Bearer token"),
      "expected the authorization header to survive, got #{peer.header("Authorization").inspect}"
  end

  def test_web_socket_transport_round_trips_messages
    server = loopback_server
    connection = dial(server, subprotocols: [ Protocol::V1JSON::SUBPROTOCOL ])
    peer = server.accept

    connection.write(%({"command":"subscribe"}))
    assert_equal %({"command":"subscribe"}), peer.read

    peer.write(Opcode::TEXT, %({"type":"welcome"}))
    assert_equal %({"type":"welcome"}), connection.read(timeout: WAIT)
  end

  def test_web_socket_transport_answers_pings
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    peer.write(Opcode::PING, "beat")
    peer.write(Opcode::TEXT, "after the ping")

    assert_equal "after the ping", connection.read(timeout: WAIT)

    frame = peer.read_frame
    assert_equal Opcode::PONG, frame.opcode, "expected a pong"
    assert_equal "beat", frame.payload, "expected the pong to carry the ping payload"
  end

  def test_web_socket_transport_reassembles_fragments
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    peer.write_fragment(Opcode::TEXT, "one ", final: false)
    peer.write_fragment(Opcode::PING, "interleaved", final: true)
    peer.write_fragment(Opcode::CONTINUATION, "message", final: true)

    assert_equal "one message", connection.read(timeout: WAIT)
  end

  def test_web_socket_transport_reads_large_messages
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    long = "cable" * 30_000
    peer.write(Opcode::TEXT, long)
    assert_equal long, connection.read(timeout: WAIT)

    connection.write(long)
    assert_equal long, peer.read
  end

  def test_web_socket_transport_refuses_oversized_messages
    server = loopback_server
    connection = dial(server, max_message_size: 8)

    server.accept.write(Opcode::TEXT, "far too long for eight bytes")

    assert_raises(ActionCableClient::MessageTooBigError) { connection.read(timeout: WAIT) }
  end

  def test_web_socket_transport_refuses_oversized_fragmented_messages
    server = loopback_server
    connection = dial(server, max_message_size: 8)

    peer = server.accept
    peer.write_fragment(Opcode::TEXT, "five ", final: false)
    peer.write_fragment(Opcode::CONTINUATION, "more", final: true)

    assert_raises(ActionCableClient::MessageTooBigError) { connection.read(timeout: WAIT) }
  end

  def test_web_socket_transport_reports_server_close
    server = loopback_server
    connection = dial(server)

    server.accept.write(Opcode::CLOSE, [ 4401 ].pack("n") + "unauthorized")

    error = assert_raises(ActionCableClient::CloseError) { connection.read(timeout: WAIT) }
    assert_equal 4401, error.code
    assert_equal "unauthorized", error.reason
  end

  def test_web_socket_transport_reports_a_server_close_without_a_status
    server = loopback_server
    connection = dial(server)

    server.accept.write(Opcode::CLOSE)

    error = assert_raises(ActionCableClient::CloseError) { connection.read(timeout: WAIT) }
    assert_equal 1005, error.code
    assert_equal "", error.reason
  end

  def test_web_socket_transport_closes_with_a_status
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    assert_respond_to connection, :close_with_status, "the built-in connection should be able to say why"
    connection.close_with_status(4000, "done here")

    frame = peer.read_frame
    assert_equal Opcode::CLOSE, frame.opcode
    assert_equal 4000, frame.payload.unpack1("n")
    assert_equal "done here", frame.payload.byteslice(2..)
  end

  def test_web_socket_transport_truncates_a_close_reason_to_fit_the_frame
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    connection.close_with_status(4000, "r" * 200)

    frame = peer.read_frame
    assert_equal Opcode::CLOSE, frame.opcode
    assert_equal 125, frame.payload.bytesize, "a control frame's payload is at most 125 bytes"
  end

  def test_web_socket_transport_refuses_a_non_upgrade_response
    server = loopback_server
    server.refusal = "HTTP/1.1 404 Not Found\r\nContent-Length: 13\r\n\r\nno cable here"

    error = assert_raises(ActionCableClient::HandshakeError) { transport.dial(server.url) }
    assert_equal 404, error.status_code
    assert_equal "404 Not Found", error.status
  end

  def test_web_socket_transport_does_not_follow_a_redirect
    server = loopback_server
    server.refusal = "HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n"

    error = assert_raises(ActionCableClient::HandshakeError) { transport.dial(server.url) }
    assert_equal 302, error.status_code
  end

  def test_web_socket_transport_refuses_a_bad_accept_key
    server = loopback_server
    server.bad_accept = true

    assert_raises(ActionCableClient::Error) { transport.dial(server.url) }
  end

  def test_web_socket_transport_honors_the_read_timeout
    server = loopback_server
    connection = dial(server)
    server.accept

    assert_raises(ActionCableClient::TimeoutError) { connection.read(timeout: 0.05) }
  end

  def test_web_socket_transport_refuses_a_masked_server_frame
    server = loopback_server
    connection = dial(server)

    # RFC 6455 §5.1: a server must never mask, and a client that sees a masked
    # frame must fail the connection rather than quietly unmask it.
    server.accept.write_masked(Opcode::TEXT, %({"type":"welcome"}))

    assert_raises(ActionCableClient::Error) { connection.read(timeout: WAIT) }
  end

  def test_web_socket_transport_replies_to_a_close_once
    server = loopback_server
    connection = dial(server)
    peer = server.accept

    peer.write(Opcode::CLOSE, [ 1000 ].pack("n"))
    assert_raises(ActionCableClient::CloseError) { connection.read(timeout: WAIT) }
    connection.close

    assert_equal 1, peer.close_frames(timeout: 0.2), "expected exactly one close frame in reply"
  end

  # Runs the whole cable dance over an actual WebSocket connection.
  def test_client_over_the_real_transport
    server = loopback_server
    client = ActionCableClient.new(server.url, logger: test_logger)
    (@clients ||= []) << client

    connected = connecting(client)
    peer = server.accept
    peer.write(Opcode::TEXT, %({"type":"welcome"}))
    connected.value

    pending = subscribing(client)
    assert_equal %({"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}"}), peer.read
    peer.write(Opcode::TEXT, %({"type":"confirm_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}"}))
    subscription = pending.value

    peer.write(Opcode::TEXT,
      %({"identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}","message":{"body":"Hello!"}}))
    assert_equal %({"body":"Hello!"}), subscription.next_message(timeout: WAIT).to_s

    subscription.perform("speak", body: "Hi!")
    assert_equal %({"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\",\\"id\\":42}",) +
      %("data":"{\\"action\\":\\"speak\\",\\"body\\":\\"Hi!\\"}"}), peer.read
  end

  def teardown
    @connections&.each(&:close)
    super
  end

  private
    def transport(**options)
      ActionCableClient::WebSocketTransport.new(**options)
    end

    def dial(server, subprotocols: [], headers: {}, **options)
      connection = transport(**options).dial(server.url, subprotocols: subprotocols, headers: headers)
      (@connections ||= []) << connection

      connection
    end
end
