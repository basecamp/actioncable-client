# frozen_string_literal: true

module ActionCableClient
  # Runs a subscription's callbacks on their own thread, one at a time, in the
  # order the events happened.
  #
  # Callbacks belong off the connection's thread: an on_disconnected that closes
  # the client or an on_connected that subscribes are both reasonable things to
  # write, and both wait on work only the connection thread can do. The queue is
  # unbounded for the same reason — handing an event over must never block the
  # connection.
  #
  # Once stopped it runs what it still holds, turns away anything handed to it
  # after that, then calls the block it was built with. That is how a
  # subscription closes its messages only after its last callback has returned,
  # with none left behind unrun.
  class Dispatcher
    def initialize(logger, &after_stop)
      @logger = logger
      @callbacks = Queue.new
      @after_stop = after_stop
      @thread = Thread.new { run }
    end

    def dispatch(&callback)
      @callbacks.push(callback)
    rescue ClosedQueueError
      nil
    end

    # Lets the dispatcher finish what it has and go away. It doesn't wait, since
    # a callback is allowed to be what stopped it.
    def stop
      @callbacks.close
    end

    private
      def run
        while (callback = @callbacks.pop)
          call(callback)
        end

        @after_stop.call
      end

      # A callback that raises takes its own event down and nothing else. A
      # thread that died on one would leave every later callback unrun and the
      # messages never closed, which is a worse answer than saying so and
      # carrying on.
      def call(callback)
        callback.call
      rescue StandardError => error
        @logger.warn("actioncable: a subscription callback raised: #{error.class}: #{error.message}")
      end
  end
end
