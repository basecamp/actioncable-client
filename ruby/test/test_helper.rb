# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "actioncable_client"
require "actioncable_client/testing"
require "minitest/autorun"

require_relative "support/loopback_server"

# How long a test will hang around for something that should already have
# happened.
WAIT = 2.0

# Runs a block on its own thread and holds what it returned or raised, because
# most of what this client does is answered by a server the test still has to
# play.
class Future
  def initialize(&block)
    @thread = Thread.new do
      block.call
    rescue StandardError => error
      error
    end
  end

  # What the block returned, re-raising whatever it raised.
  def value(timeout: WAIT)
    outcome = result(timeout: timeout)
    raise outcome if outcome.is_a?(StandardError)

    outcome
  end

  # What the block raised.
  def error(timeout: WAIT)
    outcome = result(timeout: timeout)
    raise Minitest::Assertion, "expected it to raise, it returned #{outcome.inspect}" unless
      outcome.is_a?(StandardError)

    outcome
  end

  # Whether it is still waiting on something.
  def pending?(timeout)
    !@thread.join(timeout)
  end

  private
    def result(timeout:)
      unless @thread.join(timeout)
        @thread.kill
        raise Minitest::Assertion, "it never finished within #{timeout} seconds"
      end

      @thread.value
    end
end

# The setup every test here shares: a client over a fake transport, and the
# handful of moves — connect, welcome, subscribe, confirm — that every test
# starts from.
class CableTest < Minitest::Test
  ROOM = %({"channel":"RoomChannel","id":42})
  OTHER = %({"channel":"OtherChannel"})

  def teardown
    @clients&.each(&:close)
    @servers&.each(&:close)
  end

  private
    def test_client(transport, **options)
      client = ActionCableClient.new("ws://cable.example.com/cable",
        transport: transport, logger: test_logger, **options)
      (@clients ||= []) << client

      client
    end

    def fake_transport
      ActionCableClient::Testing::FakeTransport.new
    end

    def loopback_server
      server = LoopbackServer.new
      (@servers ||= []) << server

      server
    end

    def room
      ActionCableClient::Identifier.new("RoomChannel", id: 42)
    end

    def connecting(client, **options)
      Future.new { client.connect(**options) }
    end

    # Connects a client and plays the server's welcome, returning the
    # connection the test can go on talking over.
    def welcomed(client, transport)
      connected = connecting(client)
      connection = transport.accept
      connection.welcome
      connected.value

      connection
    end

    # Subscribes in the background, since #subscribe waits for the
    # confirmation the test still has to send.
    def subscribing(client, identifier = room, **options)
      Future.new { client.subscribe(identifier, **options) }
    end

    def subscribed(client, connection)
      pending = subscribing(client)
      assert_command connection, "subscribe", ROOM
      connection.confirm(ROOM)

      pending.value
    end

    def assert_command(connection, name, identifier)
      command = connection.command
      assert_equal name, command["command"]
      assert_equal identifier, command["identifier"]

      command
    end

    # Sends the client's chatter to the test output when a test is being
    # debugged, and swallows it otherwise.
    def test_logger
      if ENV["CABLE_LOG"]
        ->(message) { warn message }
      end
    end
end
