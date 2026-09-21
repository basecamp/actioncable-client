# frozen_string_literal: true

module ActionCableClient
  class WebSocketTransport
    # One live RFC 6455 connection: reads frames and reassembles them into
    # messages, masks what it sends, answers pings, and hangs up with a close
    # frame.
    class Connection
      # RFC 6455 §7.4.1's two codes this side needs by name: the one a close
      # frame carries by default, and the one that stands in for a frame
      # carrying none.
      NORMAL_CLOSURE = 1000
      GOING_AWAY = 1001
      NO_STATUS = 1005

      # What fits in a close frame after the code: a control frame's payload is
      # at most 125 bytes.
      MAX_CLOSE_REASON_BYTES = 123

      attr_reader :subprotocol

      def initialize(socket, subprotocol:, write_timeout:, max_message_size:)
        @socket = socket
        # An SSL socket buffers inside the library, so a wait for readiness
        # goes to the raw socket underneath it.
        @io = socket.respond_to?(:to_io) ? socket.to_io : socket
        @subprotocol = subprotocol
        @write_timeout = write_timeout
        @max_message_size = max_message_size

        @write_mutex = Mutex.new
        @close_mutex = Mutex.new
        @close_sent = false
        @closed = false
      end

      # The next complete message, waiting at most timeout seconds for one.
      def read(timeout: nil)
        deadline = Deadline.in(timeout)
        message = nil

        loop do
          frame = read_frame(deadline)

          case frame.opcode
          when Opcode::TEXT, Opcode::BINARY
            fail_with("received a new data frame in the middle of a fragmented message") if message
            return finish(frame.payload) if frame.final?

            message = frame.payload
          when Opcode::CONTINUATION
            fail_with("received a continuation frame outside a fragmented message") unless message
            if message.bytesize + frame.payload.bytesize > @max_message_size
              fail_with("a message past #{@max_message_size} bytes", MessageTooBigError)
            end

            message << frame.payload
            return finish(message) if frame.final?
          when Opcode::PING
            write_frame(Opcode::PONG, frame.payload, deadline)
          when Opcode::PONG
            nil
          when Opcode::CLOSE
            return hang_up(frame)
          else
            fail_with("received unknown opcode #{format("%#x", frame.opcode)}")
          end
        end
      end

      # Sends one text message, waiting at most timeout seconds to get it out.
      def write(payload, timeout: nil)
        write_frame(Opcode::TEXT, payload, Deadline.in(timeout || @write_timeout))
      end

      def close
        close_with_status(NORMAL_CLOSURE, "")
      end

      # Hangs up with a code and reason of the caller's choosing, where #close
      # sends 1000. The close frame is written with a short deadline and the
      # socket closed right after, whether or not the server answers: waiting
      # on a peer that may already be gone would hold up whoever is hanging up.
      def close_with_status(code, reason = "")
        @close_mutex.synchronize do
          return if @closed

          @closed = true
          send_close(code, reason)
        end

        @socket.close
        nil
      rescue IOError, SystemCallError
        nil
      end

      def closed?
        @close_mutex.synchronize { @closed }
      end

      private
        def send_close(code, reason)
          @write_mutex.synchronize do
            write_masked(Opcode::CLOSE, close_payload(code, reason), Deadline.in(1)) unless @close_sent
          end
        rescue StandardError
          nil
        end

        # A text frame is UTF-8 by definition, and what comes back out of here
        # is handed to a JSON parser that needs to know it.
        def finish(message)
          message.force_encoding(Encoding::UTF_8)
        end

        def hang_up(frame)
          # One close frame in reply, then the socket goes: #close sees the
          # reply was already sent and won't send a second one.
          @write_mutex.synchronize do
            write_masked(Opcode::CLOSE, close_reply(frame.payload), Deadline.in(1))
          rescue StandardError
            nil
          end
          close

          raise close_error(frame.payload)
        end

        def read_frame(deadline)
          header = read_bytes(2, deadline)
          first, second = header.unpack("C2")

          fail_with("received a frame with reserved bits set") if first.anybits?(0x70)

          # RFC 6455 §5.1: a server must not mask what it sends, and a client
          # that receives a masked frame must fail the connection.
          fail_with("received a masked frame from the server") if second.anybits?(0x80)

          frame = Frame.new(final: first.anybits?(0x80), opcode: first & 0x0f, payload: "")
          length = frame_length(second & 0x7f, deadline)

          if frame.control? && (!frame.final? || length > 125)
            fail_with("received a fragmented or oversized control frame")
          end
          if length > @max_message_size
            fail_with("a #{length} byte frame against a limit of #{@max_message_size}", MessageTooBigError)
          end

          frame.with(payload: read_bytes(length, deadline))
        end

        def frame_length(length, deadline)
          case length
          when 126 then read_bytes(2, deadline).unpack1("n")
          when 127 then read_bytes(8, deadline).unpack1("Q>") & 0x7fffffffffffffff
          else length
          end
        end

        def write_frame(opcode, payload, deadline)
          @write_mutex.synchronize { write_masked(opcode, payload, deadline) }
        end

        def write_masked(opcode, payload, deadline)
          @close_sent = true if opcode == Opcode::CLOSE
          payload = payload.to_s.b
          mask = Random.urandom(4)

          write_bytes(header_for(opcode, payload.bytesize) + mask + apply_mask(mask, payload), deadline)
        end

        def header_for(opcode, length)
          case length
          when 0..125 then [ 0x80 | opcode, 0x80 | length ].pack("C2")
          when 126..0xffff then [ 0x80 | opcode, 0x80 | 126, length ].pack("C2n")
          else [ 0x80 | opcode, 0x80 | 127, length ].pack("C2Q>")
          end
        end

        def apply_mask(mask, payload)
          masked = payload.dup
          payload.bytesize.times { |index| masked.setbyte(index, payload.getbyte(index) ^ mask.getbyte(index % 4)) }

          masked
        end

        # The close frame sent back for one the server sent: its own code
        # echoed when we're allowed to send it ourselves — normal, going away,
        # or an application's own — and normal closure otherwise.
        def close_reply(received)
          echoed = received.bytesize >= 2 ? received.unpack1("n") : nil
          allowed = echoed && (echoed >= 3000 || echoed == NORMAL_CLOSURE || echoed == GOING_AWAY)

          close_payload(allowed ? echoed : NORMAL_CLOSURE, "")
        end

        # A close frame's payload: the code, then as much of the reason as a
        # control frame has room for.
        def close_payload(code, reason)
          [ code ].pack("n") + reason.to_s.b.byteslice(0, MAX_CLOSE_REASON_BYTES)
        end

        def close_error(payload)
          if payload.bytesize < 2
            CloseError.new(code: NO_STATUS)
          else
            CloseError.new(code: payload.unpack1("n"), reason: payload.byteslice(2..).force_encoding(Encoding::UTF_8))
          end
        end

        # Fails the connection: a frame we can't trust means the peer isn't
        # speaking the protocol, and reading on would be guesswork.
        def fail_with(reason, error = Error)
          close
          raise error, reason
        end

        def read_bytes(count, deadline)
          buffer = +""
          buffer.force_encoding(Encoding::BINARY)

          while buffer.bytesize < count
            buffer << read_some(count - buffer.bytesize, deadline)
          end

          buffer
        end

        def read_some(count, deadline)
          @socket.read_nonblock(count)
        rescue IO::WaitReadable
          await(:readable, deadline)
          retry
        rescue IO::WaitWritable
          await(:writable, deadline)
          retry
        rescue EOFError
          raise Error, "the server hung up"
        end

        def write_bytes(bytes, deadline)
          written = 0

          while written < bytes.bytesize
            written += write_some(bytes.byteslice(written..), deadline)
          end

          nil
        end

        def write_some(bytes, deadline)
          @socket.write_nonblock(bytes)
        rescue IO::WaitWritable
          await(:writable, deadline)
          retry
        rescue IO::WaitReadable
          await(:readable, deadline)
          retry
        end

        # Waits for the socket, and raises rather than waiting past the
        # deadline.
        def await(direction, deadline)
          remaining = deadline.remaining
          raise TimeoutError, "the connection went quiet" if remaining&.zero?

          ready = if direction == :readable
            @io.wait_readable(remaining)
          else
            @io.wait_writable(remaining)
          end

          raise TimeoutError, "the connection went quiet" unless ready
        end
    end
  end
end
