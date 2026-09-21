# frozen_string_literal: true

require_relative "actioncable_client/version"
require_relative "actioncable_client/errors"
require_relative "actioncable_client/deadline"
require_relative "actioncable_client/logger"
require_relative "actioncable_client/headers"
require_relative "actioncable_client/message"
require_relative "actioncable_client/identifier"
require_relative "actioncable_client/protocol"
require_relative "actioncable_client/protocol/v1_json"
require_relative "actioncable_client/transport"
require_relative "actioncable_client/web_socket_transport"
require_relative "actioncable_client/web_socket_transport/frame"
require_relative "actioncable_client/web_socket_transport/handshake"
require_relative "actioncable_client/web_socket_transport/connection"
require_relative "actioncable_client/dispatcher"
require_relative "actioncable_client/registration"
require_relative "actioncable_client/subscription"
require_relative "actioncable_client/client"

# A client for Rails' Action Cable.
#
# A Client owns one WebSocket connection to an Action Cable server and
# multiplexes any number of channel subscriptions over it. It keeps the
# connection alive the way the official JavaScript client does: the server
# beats a ping every three seconds, and a connection that goes quiet for
# longer than stale_after is torn down and redialed with backoff.
# Subscriptions survive reconnects — they are resubscribed as soon as the
# server says welcome.
#
#   client = ActionCableClient.new("wss://example.com/cable")
#   client.connect(timeout: 10)
#
#   room = client.subscribe(ActionCableClient::Identifier.new("RoomChannel", id: 42))
#
#   Thread.new { room.each { |message| puts message.parse["body"] } }
#
#   room.perform("speak", body: "Hello!")
#
# Two things are pluggable. A transport carries bytes — the built-in
# WebSocketTransport speaks RFC 6455 over the standard library, and any
# WebSocket library can be dropped in behind the same handful of messages. A
# protocol speaks one Action Cable wire format, negotiated as one WebSocket
# subprotocol — Protocol::V1JSON implements actioncable-v1-json, and a new
# format is a new protocol rather than a fork of this client.
#
# The name stays out of Rails' own ActionCable namespace on purpose: a gem
# that defined ActionCable::Client would be reaching into Rails'.
module ActionCableClient
  # Builds a client for an Action Cable endpoint. See Client#initialize for
  # everything it takes.
  def self.new(...)
    Client.new(...)
  end
end
