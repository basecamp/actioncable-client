# frozen_string_literal: true

require "json"

module ActionCableClient
  module Testing
    # Hands out in-memory connections a test plays the server on. Pass one in
    # place of a WebSocketTransport and nothing touches the network:
    #
    #   transport = ActionCableClient::Testing::FakeTransport.new
    #   client = ActionCableClient::Client.new("ws://cable.test/cable", transport: transport)
    #
    #   connecting = Thread.new { client.connect }
    #   server = transport.accept
    #   server.welcome
    #   connecting.join
    #
    # Every wait here takes a timeout and raises TimeoutError rather than
    # hanging, so a test that got the dance wrong fails instead of stalling.
    class FakeTransport
      # How long anything here waits for something that should already have
      # happened.
      WAIT = 2.0

      # What the server negotiates. Set it to something else to watch the
      # client refuse a subprotocol it doesn't speak.
      attr_accessor :subprotocol

      # How many commands a connection takes before a write waits on the test
      # reading them. Zero makes every write wait, which lets a test hold the
      # client mid-write.
      attr_accessor :write_buffer

      # The options the client last dialed with, as { subprotocols:, headers: }.
      attr_reader :dialed_with

      def initialize(subprotocol: Protocol::V1JSON::SUBPROTOCOL)
        @subprotocol = subprotocol
        @write_buffer = 32
        @dialed = Channel.new(16)
        @dial_errors = []
        @mutex = Mutex.new
      end

      def dial(url, subprotocols: [], headers: {})
        error = @mutex.synchronize do
          @dialed_with = { subprotocols: subprotocols, headers: headers }
          @dial_errors.shift
        end
        raise error if error

        FakeConnection.new(subprotocol: subprotocol, write_buffer: write_buffer).tap do |connection|
          @dialed.send(connection, timeout: WAIT)
        end
      end

      # Turns the next dial down with the error given, the way a refused
      # connection does.
      def fail_next_dial(error)
        @mutex.synchronize { @dial_errors << error }
      end

      # The next connection the client dials, waiting for one.
      def accept(timeout: WAIT)
        @dialed.receive(timeout: timeout) or raise Error, "no connection was dialed"
      rescue TimeoutError
        raise TimeoutError, "no connection was dialed"
      end

      # Whether the client leaves the transport alone for a while. Raises when
      # it dials instead.
      def refuse_dial(timeout: 0.2)
        connection = @dialed.receive(timeout: timeout)
        return true if connection.nil?

        raise Error, "expected no connection, got one speaking #{connection.subprotocol}"
      rescue TimeoutError
        true
      end
    end

    # One connection with the test playing the server on the other end. Like
    # Rails it keeps one subscription per identifier: a subscribe for an
    # identifier it has already heard, answered or not, is ignored.
    class FakeConnection
      attr_reader :subprotocol

      def initialize(subprotocol:, write_buffer:)
        @subprotocol = subprotocol
        @incoming = Channel.new
        @outgoing = Channel.new(write_buffer)
        # Ticks as each write begins, so a test can tell the client is stuck
        # in one before anyone reads what it wrote.
        @writing = Channel.new(64)
        @subscribed = {}
        @mutex = Mutex.new
        @closed = false
      end

      def read(timeout: nil)
        payload = @incoming.receive(timeout: timeout)
        raise Error, "the connection is closed" if payload.nil?

        payload
      end

      def write(payload, timeout: nil)
        return nil if ignores?(payload)

        tick
        @outgoing.send(payload, timeout: timeout)
        nil
      rescue Channel::Closed
        raise Error, "the connection is closed"
      end

      def close
        @mutex.synchronize { @closed = true }
        @incoming.close
        @outgoing.close
        @writing.close
        nil
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      # Plays a server frame to the client, waiting for it to be read.
      def push(frame, timeout: FakeTransport::WAIT)
        @incoming.send(frame, timeout: timeout)
      rescue Channel::Closed
        raise Error, "the connection closed before #{frame} could be sent"
      end

      def welcome
        push(%({"type":"welcome"}))
      end

      def ping(at = Time.now.to_i)
        push(%({"type":"ping","message":#{at}}))
      end

      def confirm(identifier)
        push(%({"type":"confirm_subscription","identifier":#{identifier.to_json}}))
      end

      # Turns a subscription down, which also forgets it: the client is free to
      # try again.
      def reject(identifier)
        @mutex.synchronize { @subscribed.delete(identifier) }
        push(%({"type":"reject_subscription","identifier":#{identifier.to_json}}))
      end

      def broadcast(identifier, message)
        push(%({"identifier":#{identifier.to_json},"message":#{message.to_json}}))
      end

      def disconnect(reason, reconnect:)
        push(%({"type":"disconnect","reason":#{reason.to_json},"reconnect":#{reconnect}}))
      end

      # The next payload the client writes, exactly as it went out.
      def sent(timeout: FakeTransport::WAIT)
        @outgoing.receive(timeout: timeout) or raise Error, "the connection closed before anything was sent"
      rescue TimeoutError
        raise TimeoutError, "the client sent nothing"
      end

      # The next command the client sends. Nobody has heard it yet: #command
      # and #drop_command settle that.
      def next_command(timeout: FakeTransport::WAIT)
        JSON.parse(sent(timeout: timeout))
      end

      # The next command the client sends, taken in the way the server would.
      def command(timeout: FakeTransport::WAIT)
        next_command(timeout: timeout).tap { |command| hear(command) }
      end

      # Lets the next command fall on the floor, the way the server drops a
      # subscribe that reaches it before the connection is set up.
      def drop_command(timeout: FakeTransport::WAIT)
        next_command(timeout: timeout)
      end

      # Whether the client keeps quiet for a while. Raises when it sends
      # something instead.
      def quiet?(timeout: 0.1)
        payload = @outgoing.receive(timeout: timeout)
        return true if payload.nil?

        raise Error, "expected no command, got #{payload}"
      rescue TimeoutError
        true
      end

      # Waits until the client is inside a write, for a test that wants to
      # catch it there.
      def writing(timeout: FakeTransport::WAIT)
        @writing.receive(timeout: timeout)
      end

      private
        # Best effort: a test that isn't watching writes shouldn't hold one up.
        def tick
          @writing.send(true, timeout: 0)
        rescue TimeoutError, Channel::Closed
          nil
        end

        # Whether the server would drop the command without a word: Rails does
        # that to a second subscribe for an identifier the connection already
        # has.
        def ignores?(payload)
          command = JSON.parse(payload)
          @mutex.synchronize { command["command"] == "subscribe" && @subscribed[command["identifier"]] }
        rescue JSON::ParserError
          false
        end

        def hear(command)
          @mutex.synchronize do
            case command["command"]
            when "subscribe" then @subscribed[command["identifier"]] = true
            when "unsubscribe" then @subscribed.delete(command["identifier"])
            end
          end
        end
    end
  end
end
