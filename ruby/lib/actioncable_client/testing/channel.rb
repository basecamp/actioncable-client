# frozen_string_literal: true

module ActionCableClient
  module Testing
    # A handoff between two threads, with room for a fixed number of values in
    # between. With no room at all a send waits for a receive, which is what
    # lets a test hold the client mid-write and watch what queues up behind it.
    # Closing it wakes everyone: a receive then answers nil and a send gives
    # up.
    class Channel
      class Closed < StandardError; end

      def initialize(capacity = 0)
        @capacity = capacity
        @values = []
        @mutex = Mutex.new
        @changed = ConditionVariable.new
        @closed = false
      end

      # Hands a value over, waiting for room — or, with no room at all, for
      # somebody to take it. Raises Closed when the channel goes while waiting,
      # and TimeoutError when the wait runs out.
      def send(value, timeout: nil)
        deadline = Deadline.in(timeout)
        handed = [ value, false ]

        @mutex.synchronize do
          wait_in(deadline) { @closed || @values.size < room }
          raise Closed if @closed

          @values << handed
          @changed.broadcast

          if @capacity.zero?
            wait_in(deadline) { @closed || handed.last }
            raise Closed unless handed.last
          end
        end

        value
      end

      # Takes the next value, or nil once the channel is closed and empty.
      # Raises TimeoutError when the wait runs out with the channel still open.
      def receive(timeout: nil)
        deadline = Deadline.in(timeout)

        @mutex.synchronize do
          wait_in(deadline) { @closed || @values.any? }
          return nil if @values.empty? && @closed

          value, = handed = @values.shift
          handed[1] = true
          @changed.broadcast

          value
        end
      end

      # Whether anything is waiting to be taken. A sender with no room parks
      # its value here, so this says a write is in flight as well as buffered.
      def any?
        @mutex.synchronize { @values.any? }
      end

      def close
        @mutex.synchronize do
          @closed = true
          @changed.broadcast
        end
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      private
        # With no capacity the value still has to go somewhere for the receiver
        # to find, so one slot is kept and the sender waits for it to be
        # emptied rather than for room to put it in.
        def room
          @capacity.zero? ? 1 : @capacity
        end

        def wait_in(deadline)
          until yield
            remaining = deadline.remaining
            raise TimeoutError, "the channel did not answer" if remaining&.zero?

            @changed.wait(@mutex, remaining)
          end
        end
    end
  end
end
