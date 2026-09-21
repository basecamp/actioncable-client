# frozen_string_literal: true

module ActionCableClient
  # Transports dial the network connection a client talks over. This is the
  # seam where a network handler plugs in: the built-in WebSocketTransport
  # speaks RFC 6455 on the standard library, and wrapping faye-websocket, a
  # WebSocket of an application's own, or an in-memory pipe for tests means
  # answering these two sets of messages and nothing else.
  #
  # A transport answers:
  #
  #   dial(url, subprotocols:, headers:) -> connection
  #
  # where subprotocols are the ones the client's protocols negotiate under and
  # headers are what authorizes the request — a cookie or a token, since an
  # Action Cable server authorizes the upgrade request itself.
  #
  # A connection answers:
  #
  #   subprotocol            what the server negotiated, nil if it named none
  #   read(timeout:)         the next complete message, as a String
  #   write(payload, timeout:)  sends one text message
  #   close                  hangs up
  #
  # #read and #write are each called from one thread at a time, but #close may
  # be called alongside either and has to interrupt it. A #read that runs out
  # of time raises TimeoutError; one on a connection that is finished raises.
  #
  # A connection that can say why it is hanging up also answers
  # close_with_status(code, reason), where #close sends 1000 Normal Closure.
  # The built-in transport's connections do.
  module Transport
  end
end
