# frozen_string_literal: true

module ActionCableClient
  # A moment to be finished by. Where the Go client threads a context through
  # everything that can wait, this carries the same thing a timeout argument
  # means: turn the caller's "within this many seconds" into an instant, so a
  # call that waits several times over doesn't get the whole allowance each
  # time. A deadline built from nil never runs out.
  class Deadline
    # Builds a deadline seconds from now, or one that never runs out when
    # seconds is nil.
    def self.in(seconds)
      new(seconds && now + seconds)
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def initialize(at = nil)
      @at = at
    end

    # How long there is left, or nil when there is no deadline at all. Never
    # negative: a deadline that has passed has no time left rather than time
    # owed, which is what every wait this is handed to expects.
    def remaining
      if @at
        [ @at - self.class.now, 0.0 ].max
      end
    end

    def past?
      !remaining.nil? && remaining.zero?
    end
  end
end
