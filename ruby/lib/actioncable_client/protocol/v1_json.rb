# frozen_string_literal: true

require "json"

module ActionCableClient
  module Protocol
    # The actioncable-v1-json protocol: JSON objects in text frames, keyed by
    # command going out and by type coming in. Every Rails Action Cable server
    # speaks it, and it is what a client offers unless told otherwise.
    class V1JSON
      SUBPROTOCOL = "actioncable-v1-json"

      # The frame types Rails names, and what this client calls each.
      KINDS = {
        "welcome" => :welcome,
        "ping" => :ping,
        "disconnect" => :disconnect,
        "confirm_subscription" => :confirmation,
        "reject_subscription" => :rejection
      }.freeze

      def subprotocol
        SUBPROTOCOL
      end

      def encode(command)
        fields = { "command" => command.name.to_s, "identifier" => command.identifier }
        fields["data"] = command.data if command.data
        JSON.generate(fields)
      end

      def decode(payload)
        frame = JSON.parse(payload)
        raise Error, "decoding #{truncate(payload)}: expected a JSON object" unless frame.is_a?(Hash)

        Incoming.new(
          kind: kind_of(frame),
          identifier: frame["identifier"],
          message: Message.new(raw_message(frame)),
          reason: frame["reason"],
          reconnect: frame["reconnect"] == true
        )
      rescue JSON::ParserError => error
        raise Error, "decoding #{truncate(payload)}: #{error.message}"
      end

      private
        # Anything without a recognized type is a channel message, which is how
        # the server sends them: an identifier and a message, and no type at all.
        def kind_of(frame)
          KINDS.fetch(frame["type"], :message)
        end

        # The message stays as the JSON it arrived as rather than as a parsed
        # object, because only the channel knows what shape it is in.
        def raw_message(frame)
          frame["message"].to_json if frame.key?("message")
        end

        def truncate(payload, limit = 200)
          if payload.length > limit
            "#{payload[0, limit]}…"
          else
            payload
          end
        end
    end
  end
end
