# frozen_string_literal: true

require "json"

module ActionCableClient
  # Names one subscription. It is encoded as a JSON object and the server treats
  # that encoding as an opaque key, echoing it back on every frame it sends for
  # the subscription.
  #
  #   ActionCableClient::Identifier.new("RoomChannel", id: 42)
  #
  # A channel with no params needs only the name.
  class Identifier
    attr_reader :channel, :params

    # Takes an Identifier as it is, and a bare channel name as an Identifier
    # with no params, so a caller with nothing to add can pass the string.
    def self.wrap(identifier)
      case identifier
      when Identifier then identifier
      when String, Symbol then new(identifier)
      else raise ArgumentError, "expected an Identifier or a channel name, got #{identifier.inspect}"
      end
    end

    def initialize(channel, params = {})
      @channel = channel.to_s
      @params = params
    end

    # The JSON object the server knows this subscription by. Keys are sorted, so
    # the same channel and params always key the same way and two callers
    # naming them in a different order share one subscription.
    def key
      JSON.generate(params.transform_keys(&:to_s).merge("channel" => channel).sort.to_h)
    rescue JSON::JSONError => error
      raise Error, "encoding identifier for #{channel.inspect}: #{error.message}"
    end

    def to_s
      key
    rescue Error
      "#{channel}(#{params.inspect})"
    end

    def ==(other)
      other.is_a?(Identifier) && other.channel == channel && other.params == params
    end
    alias_method :eql?, :==

    def hash
      [ channel, params ].hash
    end

    def inspect
      "#<ActionCableClient::Identifier #{self}>"
    end
  end
end
