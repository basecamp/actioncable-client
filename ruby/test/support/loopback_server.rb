# frozen_string_literal: true

require "socket"

# Speaks just enough of the server side of RFC 6455 to exercise the transport:
# it does the upgrade by hand and then hands the raw connection over, so what
# the tests prove is the client's own framing rather than two libraries
# agreeing with each other.
class LoopbackServer
  Opcode = ActionCableClient::WebSocketTransport::Opcode
  Handshake = ActionCableClient::WebSocketTransport::Handshake

  Request = Data.define(:verb, :target, :headers)

  # Answers the upgrade with the wrong Sec-WebSocket-Accept, for a test about
  # a server that didn't really see the request.
  attr_accessor :bad_accept

  # Answers with this raw HTTP response instead of upgrading at all.
  attr_accessor :refusal

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @accepted = Queue.new
    @peers = []
    @bad_accept = false
    @thread = Thread.new { serve }
  end

  def url
    "ws://127.0.0.1:#{@server.addr[1]}/cable"
  end

  # The next client connection, once the handshake is done.
  def accept(timeout: WAIT)
    @accepted.pop(timeout: timeout) or raise "no client connected within #{timeout} seconds"
  end

  def close
    @thread.kill
    @peers.each(&:close)
    @server.close
  rescue IOError
    nil
  end

  # One accepted connection, with the test playing the server on it.
  class Peer
    Frame = Data.define(:final, :opcode, :payload)

    attr_reader :request

    def initialize(socket, request)
      @socket = socket
      @request = request
    end

    def header(name)
      request.headers[name.downcase]
    end

    # The next text message the client sent.
    def read(timeout: WAIT)
      frame = read_frame(timeout: timeout)
      raise "expected a text frame, got #{format("%#x", frame.opcode)}" unless frame.opcode == Opcode::TEXT

      frame.payload.force_encoding(Encoding::UTF_8)
    end

    def read_frame(timeout: WAIT)
      first, second = read_bytes(2, timeout).unpack("C2")
      raise "the client sent an unmasked frame" unless second.anybits?(0x80)

      length = frame_length(second & 0x7f, timeout)
      mask = read_bytes(4, timeout)
      payload = unmask(mask, read_bytes(length, timeout))

      Frame.new(final: first.anybits?(0x80), opcode: first & 0x0f, payload: payload)
    end

    def write(opcode, payload = "")
      write_fragment(opcode, payload, final: true)
    end

    def write_fragment(opcode, payload, final:)
      header = [ final ? 0x80 | opcode : opcode ]

      bytes = case payload.bytesize
      when 0..125 then (header + [ payload.bytesize ]).pack("C2")
      when 126..0xffff then (header + [ 126, payload.bytesize ]).pack("C2n")
      else (header + [ 127, payload.bytesize ]).pack("C2Q>")
      end

      @socket.write(bytes + payload.b)
    rescue IOError, SystemCallError
      nil
    end

    # Sends a frame the way only a client is allowed to: masked.
    def write_masked(opcode, payload)
      mask = "\x01\x02\x03\x04".b
      header = [ 0x80 | opcode, 0x80 | payload.bytesize ].pack("C2")

      @socket.write(header + mask + unmask(mask, payload.b))
    rescue IOError, SystemCallError
      nil
    end

    # Counts the close frames the client sends before it goes away.
    def close_frames(timeout: WAIT)
      closes = 0

      loop do
        frame = read_frame(timeout: timeout)
        closes += 1 if frame.opcode == Opcode::CLOSE
      end
    rescue StandardError
      closes
    end

    def close
      @socket.close
    rescue IOError
      nil
    end

    private
      def frame_length(length, timeout)
        case length
        when 126 then read_bytes(2, timeout).unpack1("n")
        when 127 then read_bytes(8, timeout).unpack1("Q>")
        else length
        end
      end

      def read_bytes(count, timeout)
        buffer = +"".b

        while buffer.bytesize < count
          raise "the client sent nothing within #{timeout} seconds" unless @socket.wait_readable(timeout)

          buffer << @socket.readpartial(count - buffer.bytesize)
        end

        buffer
      end

      def unmask(mask, payload)
        payload.bytesize.times { |index| payload.setbyte(index, payload.getbyte(index) ^ mask.getbyte(index % 4)) }
        payload
      end
  end

  private
    def serve
      loop { upgrade(@server.accept) }
    rescue IOError, SystemCallError
      nil
    end

    def upgrade(socket)
      request = read_request(socket)

      if refusal
        socket.write(refusal)
        socket.close
        return
      end

      socket.write(upgrade_response(request))
      @peers << (peer = Peer.new(socket, request))
      @accepted.push(peer)
    end

    def upgrade_response(request)
      accepted = bad_accept ? "obviously-wrong" : Handshake.accept_key(request.headers["sec-websocket-key"])
      response = +"HTTP/1.1 101 Switching Protocols\r\n" \
                  "Upgrade: websocket\r\n" \
                  "Connection: Upgrade\r\n" \
                  "Sec-WebSocket-Accept: #{accepted}\r\n"

      if (offered = request.headers["sec-websocket-protocol"])
        response << "Sec-WebSocket-Protocol: #{offered.split(",").first.strip}\r\n"
      end

      response << "\r\n"
    end

    def read_request(socket)
      head = +""
      head << socket.readpartial(1) until head.end_with?("\r\n\r\n")

      line, *rest = head.split("\r\n")
      verb, target, = line.split(" ")
      headers = rest.to_h do |header|
        name, value = header.split(":", 2)
        [ name.to_s.strip.downcase, value.to_s.strip ]
      end

      Request.new(verb: verb, target: target, headers: headers)
    end
end
