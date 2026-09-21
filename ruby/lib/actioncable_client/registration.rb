# frozen_string_literal: true

module ActionCableClient
  # The server's one subscription for an identifier, and every Subscription here
  # that shares it. Rails keeps one subscription per identifier per connection
  # and says nothing to a second subscribe for it, so the subscribe command, its
  # verdict, and the retries until then belong to the identifier rather than to
  # each holder. The client's lock guards it.
  class Registration
    attr_accessor :holders

    # pending is set while a subscribe is out on the connection in hand with no
    # verdict yet, confirmed once the server said yes on it. Both clear when the
    # connection drops: the next one starts over.
    attr_accessor :pending, :confirmed

    # A fresh registration starts out pending, since the subscribe goes out
    # right behind it.
    def initialize
      @holders = []
      @pending = true
      @confirmed = false
    end

    def heard?
      pending || confirmed
    end

    # A subscribe is going back out on a fresh connection, so the verdict on
    # the last one no longer stands.
    def pending!
      @pending = true
      @confirmed = false
    end

    # The connection dropped: nothing is out and nothing is confirmed until the
    # next one is welcomed.
    def reset
      @pending = false
      @confirmed = false
    end
  end
end
