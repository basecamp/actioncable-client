# frozen_string_literal: true

module ActionCableClient
  # Takes the client's chatter — dropped messages, failed connections, retries.
  # Anything with a #warn that takes a string will do, the standard library's
  # Logger included. Nothing is logged by default.
  module Logging
    # Swallows everything, which is what a client without a logger does.
    class Discard
      def warn(message)
        nil
      end
    end

    # Adapts a callable to a logger, for a caller who would rather pass a lambda
    # than write a class.
    class Callable
      def initialize(callable)
        @callable = callable
      end

      def warn(message)
        @callable.call(message)
      end
    end

    # Wraps whatever the caller gave as a logger: a logger stays as it is, a
    # lambda gets adapted, and nothing at all falls silent.
    def self.wrap(logger)
      case logger
      when nil then Discard.new
      when Proc then Callable.new(logger)
      else logger
      end
    end
  end
end
