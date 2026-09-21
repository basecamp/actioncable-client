# frozen_string_literal: true

require "json"

module ActionCableClient
  # One channel subscription on a client. Read what the channel sends with
  # #each, and talk back with #perform or #send_data.
  class Subscription
    include Enumerable

    def initialize(client, identifier, buffer, logger, on_connected: nil, on_disconnected: nil, on_rejected: nil)
      @client = client
      @identifier = identifier
      @on_connected = on_connected
      @on_disconnected = on_disconnected
      @on_rejected = on_rejected

      @messages = SizedQueue.new(buffer)
      @state = Mutex.new
      @closed = false
      @error = nil
      @confirmed = false
      @rejected = false

      @callbacks = Dispatcher.new(logger) { @messages.close }
    end

    # The JSON identifier string the server knows this subscription by, and the
    # one it echoes back on everything it sends here.
    def key
      @identifier
    end

    # Yields everything the channel broadcasts or transmits to this
    # subscription, and returns once the subscription is unsubscribed,
    # rejected, or the client stops — after the last callback has returned.
    # #error says which it was.
    #
    # Read it promptly. Messages that arrive with the buffer full are dropped
    # and logged rather than stalling the connection; the client's
    # message_buffer: sizes the buffer for a slow consumer.
    def each
      return to_enum(:each) unless block_given?

      while (message = @messages.pop)
        yield message
      end

      self
    end

    # The same stream as #each, as an Enumerator, for a caller that would rather
    # hold it than be called back.
    def messages
      to_enum(:each)
    end

    # The next message, waiting at most timeout seconds for one. Returns nil
    # once the subscription has ended and nothing is left, and raises
    # TimeoutError when the wait runs out with the subscription still live.
    def next_message(timeout: nil)
      message = @messages.pop(timeout: timeout)
      raise TimeoutError, "no message in #{timeout} seconds" if message.nil? && !@messages.closed?

      message
    end

    # Why the subscription ended: an UnsubscribedError, a RejectedError, or
    # whatever stopped the client. Nil while the subscription is live.
    def error
      @state.synchronize { @error }
    end

    # Invokes an action on the channel — the equivalent of the JavaScript
    # client's perform. The data must encode to a JSON object, and the usual
    # way to give it is as keywords:
    #
    #   room.perform("speak", body: "Hello!")
    #
    # A channel whose own field is called timeout wants the hash form,
    # room.perform("speak", { timeout: 30 }), since the keyword is taken.
    def perform(action, data = nil, timeout: nil, **fields)
      @client.send_command(Protocol::Command.new(name: :message, identifier: @identifier,
        data: perform_payload(action, merged(data, fields))), timeout: timeout)
    end

    # Delivers data to the channel as it is, without naming an action. Rails
    # routes it to the channel's receive method.
    #
    # Named send_data rather than send, which every Ruby object already answers
    # to as the dynamic dispatcher.
    def send_data(data = nil, timeout: nil, **fields)
      payload = begin
        JSON.generate(merged(data, fields))
      rescue JSON::JSONError => error
        raise Error, "encoding data for #{@identifier}: #{error.message}"
      end

      @client.send_command(Protocol::Command.new(name: :message, identifier: @identifier, data: payload),
        timeout: timeout)
    end

    # Tells the server to drop the subscription and closes the message stream.
    # Reports whether the server heard about it: the local half always
    # succeeds, and a connection that is already down has already dropped the
    # subscription at the other end.
    def unsubscribe(timeout: nil)
      last, = @client.forget(self, UnsubscribedError.new)
      return false unless last

      begin
        @client.send_command(Protocol::Command.new(name: :unsubscribe, identifier: @identifier), timeout: timeout)
        true
      rescue NotConnectedError
        false
      end
    end

    def inspect
      "#<ActionCableClient::Subscription #{@identifier}>"
    end

    # The rest is the client's half of the subscription. It is public because
    # the client calls it from its own thread, not because a caller should.
    # :nodoc:

    # The server's verdict, set and read under the client's own lock — a
    # #subscribe waits on it alongside the client's state, and one lock is what
    # lets it wait on both at once.
    attr_reader :confirmed, :rejected

    def settled?
      @confirmed || @rejected
    end

    # Passes the server's verdict on. A holder that unsubscribed between the
    # registration's holders being listed and this call has nothing to hear.
    def confirm(reconnected)
      return if closed?

      # The callback is queued before the verdict is published: a #subscribe
      # woken by the verdict may unsubscribe at once, and that must not get
      # ahead of the callback for the event that woke it.
      @callbacks.dispatch { @on_connected.call(reconnected) } if @on_connected
      @client.announce { @confirmed = true }
    end

    def reject
      @callbacks.dispatch { @on_rejected.call } if @on_rejected
      @client.announce { @rejected = true }
      close(RejectedError.new(@identifier))
    end

    def disconnect(will_reconnect)
      @callbacks.dispatch { @on_disconnected.call(will_reconnect) } if @on_disconnected
    end

    def deliver(message)
      @state.synchronize do
        # A closed subscription has nothing left to receive, and nothing to
        # report.
        return true if @closed

        begin
          @messages.push(message, true)
          true
        rescue ThreadError
          false
        end
      end
    end

    # Ends the subscription for the reason given. Deliveries stop at once; the
    # message stream itself closes from the callback thread, after the
    # callbacks already queued have run, so a reader that sees it end knows no
    # callback is behind it.
    def close(reason)
      @state.synchronize do
        unless @closed
          @closed = true
          @error = reason
        end
      end

      @callbacks.stop
    end

    def closed?
      @state.synchronize { @closed }
    end

    private
      # Keywords are the everyday way to name a payload's fields, and a hash
      # is there for the field a keyword can't spell.
      def merged(data, fields)
        if fields.empty?
          data
        elsif data.nil?
          fields
        else
          data.merge(fields)
        end
      end

      def perform_payload(action, data)
        fields = {}

        if data
          encoded = begin
            JSON.generate(data)
          rescue JSON::JSONError => error
            raise Error, "encoding data for #{action.inspect}: #{error.message}"
          end

          fields = JSON.parse(encoded)
          unless fields.is_a?(Hash)
            raise Error, "data for #{action.inspect} must encode to a JSON object, got #{encoded}"
          end
        end

        JSON.generate({ "action" => action }.merge(fields.except("action")))
      end
  end
end
