# frozen_string_literal: true

require "base64"
require "digest/sha1"

module ActionCableClient
  class WebSocketTransport
    # The opening HTTP exchange: the upgrade request out, the response back,
    # and the checks that say the other end really is a WebSocket server
    # answering this request rather than something else on the same port.
    class Handshake
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

      # What a server must answer Sec-WebSocket-Accept with for the key sent.
      def self.accept_key(key)
        Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      end

      def self.nonce
        Base64.strict_encode64(Random.urandom(16))
      end

      attr_reader :status_code, :status

      def initialize(socket, deadline)
        @socket = socket
        @deadline = deadline
      end

      def request(request)
        write(request)
        read
        self
      end

      # Raises unless the server switched protocols, upgraded the connection,
      # proved it saw this request's key, and negotiated no extension it was
      # never offered.
      def verify!(key)
        raise HandshakeError.new(status_code: status_code, status: status) unless status_code == 101

        unless self["upgrade"].to_s.casecmp?("websocket")
          raise Error, "the server did not upgrade to websocket (Upgrade: #{self["upgrade"].inspect})"
        end
        unless token?(self["connection"], "upgrade")
          raise Error, "the server did not upgrade the connection (Connection: #{self["connection"].inspect})"
        end

        accepted = self["sec-websocket-accept"]
        raise Error, "the server sent a bad Sec-WebSocket-Accept: #{accepted.inspect}" unless
          accepted == self.class.accept_key(key)

        extensions = self["sec-websocket-extensions"]
        raise Error, "the server negotiated unrequested extensions: #{extensions.inspect}" if extensions

        self
      end

      def [](name)
        @headers[name]
      end

      private
        def token?(header, token)
          header.to_s.split(",").any? { |value| value.strip.casecmp?(token) }
        end

        def write(request)
          bytes = request.b
          written = 0

          while written < bytes.bytesize
            written += write_some(bytes.byteslice(written..))
          end
        end

        def write_some(bytes)
          @socket.write_nonblock(bytes)
        rescue IO::WaitWritable
          await(:writable)
          retry
        rescue IO::WaitReadable
          await(:readable)
          retry
        end

        # Reads exactly the head of the response and nothing past it: the bytes
        # after the blank line are the first frames, and they belong to the
        # connection rather than here.
        def read
          head = +""
          head.force_encoding(Encoding::BINARY)
          head << read_byte until head.end_with?("\r\n\r\n")

          parse(head)
        end

        def read_byte
          @socket.read_nonblock(1)
        rescue IO::WaitReadable
          await(:readable)
          retry
        rescue IO::WaitWritable
          await(:writable)
          retry
        rescue EOFError
          raise Error, "the server hung up during the upgrade"
        end

        def parse(head)
          line, *rest = head.force_encoding(Encoding::UTF_8).split("\r\n")
          _, code, *reason = line.to_s.split(" ")

          @status_code = code.to_i
          @status = [ code, *reason ].join(" ")
          @headers = rest.to_h do |header|
            name, value = header.split(":", 2)
            [ name.to_s.strip.downcase, value.to_s.strip ]
          end
        end

        def await(direction)
          remaining = @deadline.remaining
          raise TimeoutError, "the upgrade took too long" if remaining&.zero?

          ready = if direction == :readable
            io.wait_readable(remaining)
          else
            io.wait_writable(remaining)
          end

          raise TimeoutError, "the upgrade took too long" unless ready
        end

        def io
          @io ||= @socket.respond_to?(:to_io) ? @socket.to_io : @socket
        end
    end
  end
end
