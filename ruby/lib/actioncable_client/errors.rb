# frozen_string_literal: true

module ActionCableClient
  # Pairs an error about giving up with the failure that was being waited out,
  # so a deadline that ran out on bad credentials says so. Ruby has no error
  # wrapping to lean on here — #cause only reaches the exception a raise was
  # nested inside, and the attempt that failed was rescued long before — so the
  # error carries the one it was waiting on itself.
  module LastAttempt
    attr_reader :last_error

    private
      def with_last_attempt(message)
        if @last_error
          "#{message} (last attempt: #{@last_error.message})"
        else
          message
        end
      end
  end

  # Every error this library raises descends from Error, so one rescue catches
  # the lot.
  class Error < StandardError; end

  # Raised by a client that has been closed, or that stopped because the server
  # told it not to reconnect.
  class ClosedError < Error
    def initialize(message = "client closed")
      super
    end
  end

  # Raised when a command can't be sent because the connection is down.
  # Subscriptions recover on their own; a perform or send_data that hits this is
  # lost and must be retried.
  class NotConnectedError < Error
    def initialize(message = "not connected")
      super
    end
  end

  # Raised by #subscribe when the channel's subscribed method rejected the
  # subscription.
  class RejectedError < Error
    attr_reader :identifier

    def initialize(identifier)
      @identifier = identifier
      super("subscription rejected: #{identifier}")
    end
  end

  # Raised when the server negotiated a subprotocol the protocol adapter doesn't
  # speak. Reconnecting won't fix that, so the client stops.
  class UnsupportedSubprotocolError < Error; end

  # Raised by #connect on a client that is already running.
  class AlreadyConnectedError < Error
    def initialize(message = "already connected")
      super
    end
  end

  # Raised when there is nothing to offer the server, which means the client was
  # built with an empty list of protocols.
  class NoProtocolsError < Error
    def initialize(message = "no protocols to offer")
      super
    end
  end

  # Raised by a client that stopped because it failed as many attempts in a row
  # as max_attempts allows. #last_error is what the last of them failed on.
  class GaveUpError < Error
    include LastAttempt

    def initialize(last_error: nil)
      @last_error = last_error
      super(with_last_attempt("gave up connecting"))
    end
  end

  # Reported by a subscription's #error after #unsubscribe.
  class UnsubscribedError < Error
    def initialize(message = "unsubscribed")
      super
    end
  end

  # Raised by a connection's #read when the server sent a message larger than
  # the transport allows. The message is refused as soon as its length is known,
  # before any of it is read in, and the connection is failed.
  class MessageTooBigError < Error; end

  # Raised when something took longer than the caller allowed: a #connect that
  # ran out of time waiting for the welcome, a read on a connection that has
  # gone quiet, a write that couldn't be flushed. A #connect that timed out also
  # carries #last_error, the failure it was waiting out.
  class TimeoutError < Error
    include LastAttempt

    def initialize(message = "timed out", last_error: nil)
      @last_error = last_error
      super(with_last_attempt(message))
    end
  end

  # Raised when the server sends a disconnect frame. #reason is one of the four
  # REASONS an Action Cable server sends, and #reconnect? whether it expects the
  # client back.
  class DisconnectError < Error
    attr_reader :reason

    def initialize(reason:, reconnect:)
      @reason = reason
      @reconnect = reconnect
      super("server disconnected: #{reason}")
    end

    def reconnect?
      @reconnect
    end
  end

  # Raised when the server answered the upgrade request with something other
  # than 101 Switching Protocols. #status_code is what it answered instead, so a
  # caller can tell a redirect from a refusal; #status is the whole status line
  # as the server wrote it.
  class HandshakeError < Error
    attr_reader :status_code, :status

    def initialize(status_code:, status:)
      @status_code = status_code
      @status = status
      super("server refused the upgrade with #{status}")
    end
  end

  # Raised when the server closed the connection with a close frame. #code is
  # the status code the frame carried, 1005 when it carried none, and #reason
  # the text after it, if any.
  class CloseError < Error
    attr_reader :code, :reason

    def initialize(code:, reason: "")
      @code = code
      @reason = reason
      super([ "server closed the connection: #{code}", reason ].reject(&:empty?).join(" "))
    end
  end
end
