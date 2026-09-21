# frozen_string_literal: true

require "json"

module ActionCableClient
  # The undecoded payload a channel broadcast or transmitted. Its shape is
  # entirely up to the channel, so #parse it into whatever the channel sends.
  class Message
    def initialize(raw)
      @raw = raw.to_s
    end

    # The message as the channel meant it: whatever JSON.parse makes of the
    # payload. Pass symbolize_names: true for symbol keys.
    def parse(symbolize_names: false)
      JSON.parse(@raw, symbolize_names: symbolize_names)
    end

    def to_s
      @raw
    end

    # Already JSON, so it goes into a larger document as it stands.
    def to_json(*)
      @raw
    end

    def ==(other)
      other.is_a?(Message) && other.to_s == @raw
    end
    alias_method :eql?, :==

    def hash
      @raw.hash
    end

    def inspect
      "#<ActionCableClient::Message #{@raw}>"
    end
  end
end
