# frozen_string_literal: true

require "openssl"
require "socket"
require "uri"

module ActionCableClient
  # The built-in transport: an RFC 6455 client written on the standard
  # library, so the gem carries no dependencies. It handles the upgrade
  # handshake, masks what it sends, answers pings, and reassembles fragmented
  # messages.
  class WebSocketTransport
    # How long the upgrade request may take.
    HANDSHAKE_TIMEOUT = 10.0

    # How long a single write may take when the caller named no timeout.
    WRITE_TIMEOUT = 10.0

    # The largest message accepted, in bytes.
    MAX_MESSAGE_SIZE = 8 << 20

    # What the upgrade request says it is unless the caller says otherwise.
    USER_AGENT = "actioncable-ruby"

    # ssl_context configures wss:// connections; one verifying against the
    # system's roots is used when none is given.
    def initialize(ssl_context: nil,
                   handshake_timeout: HANDSHAKE_TIMEOUT,
                   write_timeout: WRITE_TIMEOUT,
                   max_message_size: MAX_MESSAGE_SIZE)
      @ssl_context = ssl_context
      @handshake_timeout = handshake_timeout
      @write_timeout = write_timeout
      @max_message_size = max_message_size
    end

    # Opens one connection, negotiating the subprotocols it is handed and
    # sending the headers it is handed and nothing else ambient. A server that
    # answers the upgrade with anything but 101 — a redirect included, which
    # this never follows — raises a HandshakeError with the status.
    def dial(url, subprotocols: [], headers: {})
      endpoint = parse(url)
      deadline = Deadline.in(@handshake_timeout)
      socket = open_socket(endpoint, deadline)

      begin
        connect(socket, endpoint, subprotocols, headers, deadline)
      rescue StandardError
        socket.close
        raise
      end
    end

    private
      def parse(url)
        endpoint = URI.parse(url)
        unless %w[ws wss http https].include?(endpoint.scheme&.downcase)
          raise Error, "unsupported scheme #{endpoint.scheme.inspect}"
        end

        endpoint
      rescue URI::Error => error
        raise Error, "parsing #{url.inspect}: #{error.message}"
      end

      def connect(socket, endpoint, subprotocols, headers, deadline)
        key = Handshake.nonce
        response = Handshake.new(socket, deadline)
          .request(upgrade_request(endpoint, key, subprotocols, headers))
          .verify!(key)

        Connection.new(socket, subprotocol: presence(response["sec-websocket-protocol"]),
          write_timeout: @write_timeout, max_message_size: @max_message_size)
      end

      def open_socket(endpoint, deadline)
        socket = Socket.tcp(endpoint.host, port_of(endpoint), connect_timeout: deadline.remaining)
        return socket unless secure?(endpoint)

        begin
          secure(socket, endpoint.host)
        rescue StandardError
          socket.close
          raise
        end
      rescue SystemCallError, SocketError => error
        raise Error, "dialing #{endpoint.host}:#{port_of(endpoint)}: #{error.message}"
      end

      def secure(socket, hostname)
        secured = OpenSSL::SSL::SSLSocket.new(socket, ssl_context)
        secured.hostname = hostname
        secured.sync_close = true
        secured.connect
        secured.post_connection_check(hostname) unless ssl_context.verify_mode == OpenSSL::SSL::VERIFY_NONE

        secured
      rescue OpenSSL::SSL::SSLError => error
        raise Error, "TLS handshake with #{hostname}: #{error.message}"
      end

      def ssl_context
        @ssl_context ||= OpenSSL::SSL::SSLContext.new.tap(&:set_params)
      end

      def secure?(endpoint)
        %w[wss https].include?(endpoint.scheme.downcase)
      end

      def port_of(endpoint)
        _, _, _, port, = URI.split(endpoint.to_s)
        return port.to_i if port

        secure?(endpoint) ? 443 : 80
      end

      def upgrade_request(endpoint, key, subprotocols, headers)
        header = Headers.normalize(headers)
        Headers.delete(header, "Sec-WebSocket-Extensions")
        Headers.put(header, "User-Agent", USER_AGENT) unless Headers.get(header, "User-Agent")
        Headers.put(header, "Host", authority(endpoint))
        Headers.put(header, "Upgrade", "websocket")
        Headers.put(header, "Connection", "Upgrade")
        Headers.put(header, "Sec-WebSocket-Key", key)
        Headers.put(header, "Sec-WebSocket-Version", "13")

        if subprotocols.empty?
          Headers.delete(header, "Sec-WebSocket-Protocol")
        else
          Headers.put(header, "Sec-WebSocket-Protocol", subprotocols.join(", "))
        end

        lines = header.map { |name, value| "#{name}: #{single_line(value)}\r\n" }

        "GET #{request_target(endpoint)} HTTP/1.1\r\n#{lines.join}\r\n"
      end

      # A header value carrying a newline would end the header and start
      # whatever came after it as one of its own, so the newlines become
      # spaces and the value stays the one header it was meant to be.
      def single_line(value)
        value.gsub(/[\r\n]/, " ")
      end

      def authority(endpoint)
        _, _, host, port, = URI.split(endpoint.to_s)
        port ? "#{host}:#{port}" : host
      end

      def request_target(endpoint)
        target = endpoint.path.to_s.empty? ? "/" : endpoint.path
        endpoint.query ? "#{target}?#{endpoint.query}" : target
      end

      def presence(value)
        value unless value.nil? || value.empty?
      end
  end
end
