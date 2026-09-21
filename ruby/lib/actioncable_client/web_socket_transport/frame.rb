# frozen_string_literal: true

module ActionCableClient
  class WebSocketTransport
    # RFC 6455 §5.2's frame types. Everything from CLOSE up is a control frame:
    # never fragmented, never longer than 125 bytes.
    module Opcode
      CONTINUATION = 0x0
      TEXT = 0x1
      BINARY = 0x2
      CLOSE = 0x8
      PING = 0x9
      PONG = 0xa
    end

    # One RFC 6455 frame: whether it finishes a message, what it is, and what
    # it carries.
    Frame = Data.define(:final, :opcode, :payload) do
      def final?
        final
      end

      def control?
        opcode >= Opcode::CLOSE
      end

      def data?
        opcode == Opcode::TEXT || opcode == Opcode::BINARY
      end
    end
  end
end
