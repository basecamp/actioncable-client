# frozen_string_literal: true

module ActionCableClient
  # Translates between Action Cable commands and the bytes on the wire. This is
  # the seam where an Action Cable protocol plugs in: anything answering
  # #subprotocol, #encode and #decode is one.
  #
  # One protocol speaks one subprotocol. A client offers every protocol it was
  # given and speaks the one the server picks, so supporting a new format means
  # adding a protocol rather than replacing the list.
  #
  # Implementations must be safe to use from several threads at once.
  module Protocol
    # The sentinel an Action Cable server names when it speaks none of the
    # subprotocols offered. The client offers it last on every handshake, the
    # way Rails' own clients do, so a server with nothing in common can say so
    # outright instead of leaving the subprotocol blank.
    UNSUPPORTED = "actioncable-unsupported"

    # The verbs of a client-to-server command.
    COMMANDS = %i[subscribe unsubscribe message].freeze

    # The kinds of server-to-client frame.
    KINDS = %i[welcome ping disconnect confirmation rejection message].freeze

    # The reasons an Action Cable server gives before hanging up.
    module Reasons
      UNAUTHORIZED = "unauthorized"
      INVALID_REQUEST = "invalid_request"
      SERVER_RESTART = "server_restart"
      REMOTE = "remote"

      ALL = [ UNAUTHORIZED, INVALID_REQUEST, SERVER_RESTART, REMOTE ].freeze
    end

    # A client-to-server message. +data+ carries the already encoded action
    # payload and is only set for a :message command.
    Command = Data.define(:name, :identifier, :data) do
      def initialize(name:, identifier:, data: nil)
        super
      end
    end

    # A decoded server-to-client frame. +reason+ and +reconnect+ are only set on
    # a :disconnect, +message+ on a :message and a :ping.
    Incoming = Data.define(:kind, :identifier, :message, :reason, :reconnect) do
      def initialize(kind:, identifier: nil, message: nil, reason: nil, reconnect: false)
        super
      end

      def reconnect?
        reconnect
      end
    end
  end
end
