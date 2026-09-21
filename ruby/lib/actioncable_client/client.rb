# frozen_string_literal: true

require "uri"

module ActionCableClient
  # Owns one connection to an Action Cable server and the subscriptions running
  # over it. Build one with new, start it with #connect, and hang up with
  # #close. It is safe to use from several threads at once.
  class Client
    # How long a connection may go without a frame before it counts as dead.
    # The server beats every three seconds, so this is two missed beats.
    STALE_AFTER = 6.0

    # How often an unconfirmed subscribe command is resent, like the JavaScript
    # client's guarantor.
    SUBSCRIBE_RETRY = 0.5

    INITIAL_BACKOFF = 1.0
    LONGEST_BACKOFF = 30.0

    # How many messages a subscription buffers before it starts dropping them.
    MESSAGE_BUFFER = 64

    attr_reader :url

    # Builds a client for an Action Cable endpoint, typically wss://host/cable.
    # It does not touch the network until #connect.
    #
    # transport            carries the bytes; a WebSocketTransport by default.
    # protocols            what to offer the server, most preferred first.
    # additional_protocols goes ahead of the ones already there, so preferring
    #                      a new protocol doesn't mean restating the defaults.
    # header               the headers the upgrade request carries. An Action
    #                      Cable server authorizes that request, so this is
    #                      where a session cookie or a bearer token goes.
    # header_provider      a callable asked for headers on every dial rather
    #                      than once, for a credential that expires. What it
    #                      returns is laid over the headers already set.
    # stop_on_error        a callable that recognizes a connection error
    #                      retrying cannot repair. The client stops with that
    #                      error instead of dialing again.
    # cookie, origin       shorthand for those two headers.
    # logger               takes the client's chatter. Nothing is logged by
    #                      default.
    # stale_after          how long a connection may go without a frame.
    # initial_backoff,
    # longest_backoff      the reconnect delay, doubling per failed attempt
    #                      from the first to the second, spread with jitter.
    # max_attempts         how many attempts may fail in a row before the
    #                      client stops with a GaveUpError. A welcome resets
    #                      the count, so it bounds an outage rather than the
    #                      client's lifetime. Nil keeps trying until #close.
    # subscribe_retry      how often an unconfirmed subscribe is resent.
    # message_buffer       how many messages a subscription buffers.
    def initialize(url,
                   transport: nil,
                   protocols: nil,
                   additional_protocols: nil,
                   header: {},
                   header_provider: nil,
                   stop_on_error: nil,
                   cookie: nil,
                   origin: nil,
                   logger: nil,
                   stale_after: STALE_AFTER,
                   initial_backoff: INITIAL_BACKOFF,
                   longest_backoff: LONGEST_BACKOFF,
                   max_attempts: nil,
                   subscribe_retry: SUBSCRIBE_RETRY,
                   message_buffer: MESSAGE_BUFFER)
      @url = url
      @transport = transport || WebSocketTransport.new
      @protocols = protocols_for(protocols, additional_protocols)
      @header_provider = header_provider
      @stop_on_error = stop_on_error
      @logger = Logging.wrap(logger)

      @stale_after = stale_after
      @initial_backoff = initial_backoff
      @longest_backoff = longest_backoff
      @max_attempts = max_attempts
      @subscribe_retry = subscribe_retry
      @message_buffer = message_buffer

      @header = Headers.normalize(header)
      Headers.put(@header, "Cookie", cookie) if cookie
      Headers.put(@header, "Origin", origin) if origin
      assume_origin

      @mutex = Mutex.new
      @changed = ConditionVariable.new
      @write_mutex = Mutex.new

      @connection = nil
      @protocol = nil
      @subscriptions = {}
      @attempts = 0
      @last_error = nil
      @reconnected = false
      @welcomed = false
      @ever_welcomed = false
      @stopped = false
      @finished = false
      @failure = nil
      @thread = nil
    end

    # Starts the client and returns once the server has sent its welcome.
    # Failed connection attempts are retried until that happens, the timeout
    # runs out, the server tells us not to come back, or stop_on_error
    # recognizes a failure as terminal.
    #
    # The timeout bounds the wait, not a connection that got through: that
    # lives until #close. A #connect that raises leaves the client stopped,
    # with nothing running behind it, so a client that failed to connect is one
    # to throw away. The one exception is AlreadyConnectedError, which says the
    # client was running fine before the call and still is.
    def connect(timeout: nil)
      start
      wait_for_welcome(Deadline.in(timeout))
    end

    # Whether a connection is up and welcomed.
    def connected?
      @mutex.synchronize { @welcomed && !@connection.nil? }
    end

    # Whether the client has stopped for good and will neither reconnect nor
    # deliver anything more.
    def stopped?
      @mutex.synchronize { @stopped }
    end

    # Waits until the client has stopped for good — closed, told by the server
    # not to come back, out of attempts, or unable to connect in the first
    # place — and reports whether it has. #error says why.
    def wait(timeout: nil)
      deadline = Deadline.in(timeout)

      @mutex.synchronize do
        wait_until(deadline) { @finished }
        @finished
      end
    end

    # Why the client stopped, and nil while it is still running or has yet to
    # be started.
    def error
      @mutex.synchronize { @stopped ? failure_locked : nil }
    end

    # Subscribes to a channel and returns once the server confirms it. The
    # subscription outlives reconnects — it is resubscribed automatically — so
    # it stays valid until it is unsubscribed.
    #
    # Subscribing to an identifier the client already holds shares the server's
    # one subscription for it instead of asking for another, which Rails would
    # ignore. Every subscription sharing an identifier gets every message, and
    # the server hears unsubscribe from the last one to go.
    #
    # Raises RejectedError when the channel turns the subscription down.
    def subscribe(identifier, timeout: nil, on_connected: nil, on_disconnected: nil, on_rejected: nil)
      key = Identifier.wrap(identifier).key
      subscription, confirmed, shared = enroll(key,
        on_connected: on_connected, on_disconnected: on_disconnected, on_rejected: on_rejected)

      if confirmed
        # The server said yes to this identifier on the connection in hand and
        # won't say so again, so the new holder is as confirmed as the rest.
        subscription.confirm(false)
        return subscription
      end

      # A shared identifier's subscribe is already out, or goes out with the
      # next welcome, and its verdict is this subscription's too.
      announce_subscribe(key) unless shared

      await_verdict(subscription, key, Deadline.in(timeout))
    end

    # Hangs up, stops reconnecting, and ends every subscription's message
    # stream. Safe to call from a subscription callback, and safe to call
    # twice.
    def close
      stop_with(ClosedError.new)
      await_stopped

      self
    end

    def inspect
      "#<ActionCableClient::Client #{url}>"
    end

    # The rest is the client's own machinery, reached from a Subscription
    # rather than from a caller. :nodoc:

    # Puts one command on the connection, waiting at most timeout seconds for
    # the write to go out.
    def send_command(command, timeout: nil)
      @write_mutex.synchronize { write(command, timeout: timeout) }
    end

    # Drops a subscription and reports whether it was the last one holding that
    # identifier, which is when the server needs to hear about it, and whether
    # the server has heard a subscribe for it on the connection in hand at all.
    def forget(subscription, reason)
      last, heard = @mutex.synchronize do
        registration = @subscriptions[subscription.key]
        heard = registration ? registration.heard? : false
        remaining = registration ? registration.holders.reject { |holder| holder.equal?(subscription) } : []

        if remaining.empty?
          @subscriptions.delete(subscription.key)
        else
          registration.holders = remaining
        end

        [ remaining.empty?, heard ]
      end

      subscription.close(reason)

      [ last, heard ]
    end

    # Publishes a change to the client's state and wakes everyone waiting on
    # one. A subscription's verdict lives under this lock so that a #subscribe
    # can wait on the verdict and on the client stopping at the same time.
    def announce
      @mutex.synchronize do
        yield
        @changed.broadcast
      end
    end

    private
      def protocols_for(protocols, additional)
        offered = protocols || [ Protocol::V1JSON.new ]
        Array(additional) + Array(offered)
      end

      # Fills in an Origin for the opening request when none was given. Rails
      # compares Origin against the host it serves on and turns down anything
      # else, a request carrying no Origin at all included, so the Action Cable
      # URL's own origin is the one that gets in. A server behind a proxy that
      # terminates TLS sees a different scheme than the URL says, and needs the
      # origin: argument to say so.
      def assume_origin
        return if Headers.get(@header, "Origin")

        origin = origin_of(@url)
        Headers.put(@header, "Origin", origin) if origin
      end

      def origin_of(raw_url)
        scheme, _, host, port, = URI.split(raw_url)
        authority = port ? "#{host}:#{port}" : host

        case scheme&.downcase
        when "wss", "https" then "https://#{authority}"
        when "ws", "http" then "http://#{authority}"
        end
      rescue URI::Error
        nil
      end

      def start
        @mutex.synchronize do
          raise failure_locked if @stopped
          raise AlreadyConnectedError if @thread

          @thread = Thread.new { run }
        end
      end

      def wait_for_welcome(deadline)
        welcomed = @mutex.synchronize do
          wait_until(deadline) { @ever_welcomed || @stopped }
          @ever_welcomed
        end

        if welcomed
          self
        else
          give_up_waiting
        end
      end

      # Stops a client whose #connect ran out of time, unless the welcome
      # landed in the same instant, in which case the connection is kept. Both
      # are settled under one lock, so a welcome can't slip in between the
      # check and the stop and be torn down for its trouble.
      def give_up_waiting
        stopping = @mutex.synchronize do
          unless @ever_welcomed
            mark_stopped(TimeoutError.new("timed out waiting for the welcome", last_error: @last_error))
          end

          !@ever_welcomed
        end

        if stopping
          raise await_stopped
        else
          self
        end
      end

      def run
        until stopped?
          failure = attempt
          @logger.warn("actioncable: connection to #{url} ended: #{failure.message}") if failure && !stopped?

          break if stopped?
          break unless wait_before_retry
        end
      ensure
        close_subscriptions
        finish
      end

      def attempt
        session
        nil
      rescue StandardError => error
        error
      end

      # Runs one connection from dial to hangup.
      def session
        stop_and_raise(NoProtocolsError.new) if @protocols.empty?

        connection = dial

        begin
          hold(connection, negotiated(connection.subprotocol))
        ensure
          connection.close
        end
      end

      def dial
        @transport.dial(url, subprotocols: subprotocols + [ Protocol::UNSUPPORTED ], headers: dial_header)
      rescue StandardError => error
        raise failed(error)
      end

      # What the opening request carries. Without a header_provider that is
      # what was set once, at construction; with it, what the caller says now,
      # laid over the headers already there.
      def dial_header
        if @header_provider
          Headers.merge(@header, @header_provider.call)
        else
          @header
        end
      end

      # Runs the connection until it dies, with the guarantor resending
      # unconfirmed subscribes alongside it. The connection is hung up before
      # the guarantor is joined, so a subscribe stuck half-written comes back
      # rather than holding the teardown open.
      def hold(connection, protocol)
        adopt(connection, protocol)
        stopper = Queue.new
        guarantor = Thread.new { guarantee_subscriptions(stopper) }

        begin
          receive(connection, protocol)
        rescue StandardError => error
          # Ahead of the disconnect below, so the subscriptions hear that the
          # client is not coming back rather than that it is.
          raise failed(error)
        ensure
          connection.close
          stopper.close
          guarantor.join
          disconnect
        end
      end

      # Records why an attempt ended and, when that was the last one allowed,
      # stops the client.
      def failed(error)
        return error if stopped?

        if @stop_on_error&.call(error)
          stop_with(error)
        elsif count_attempt(error) == @max_attempts
          stop_with(GaveUpError.new(last_error: error))
        end

        error
      end

      # Names every protocol the client can speak, most preferred first.
      def subprotocols
        @protocols.map(&:subprotocol)
      end

      # Finds the protocol the server picked out of the ones offered. A server
      # that picks the sentinel, names something never offered, or names
      # nothing at all leaves nothing to talk over, and dialing again won't
      # change it.
      def negotiated(subprotocol)
        protocol = @protocols.find { |candidate| candidate.subprotocol == subprotocol }
        return protocol if protocol

        if subprotocol == Protocol::UNSUPPORTED
          stop_and_raise UnsupportedSubprotocolError.new(
            "unsupported subprotocol: the server speaks none of #{subprotocols.join(", ")}")
        else
          stop_and_raise UnsupportedSubprotocolError.new("unsupported subprotocol: #{subprotocol.inspect}")
        end
      end

      def adopt(connection, protocol)
        @mutex.synchronize do
          @connection = connection
          @protocol = protocol
        end
      end

      # Reads until the connection dies. A connection that has gone quiet for
      # longer than stale_after is dead: the server beats a ping every three
      # seconds.
      def receive(connection, protocol)
        loop do
          handle(protocol, read(connection))
        end
      end

      def read(connection)
        connection.read(timeout: @stale_after)
      rescue TimeoutError
        raise TimeoutError, "no frame in #{@stale_after} seconds"
      end

      def handle(protocol, payload)
        incoming = decode(protocol, payload)
        return unless incoming

        case incoming.kind
        when :welcome then welcome
        when :ping
          # The frame itself is the heartbeat, and reading it already reset the
          # staleness deadline.
        when :disconnect then hang_up(incoming)
        when :confirmation then confirm(incoming.identifier)
        when :rejection then reject(incoming.identifier)
        when :message then deliver(incoming)
        end
      end

      def decode(protocol, payload)
        protocol.decode(payload)
      rescue Error => error
        @logger.warn("actioncable: dropping undecodable frame: #{error.message}")
        nil
      end

      # Resets the connection's health and resubscribes everything, the way the
      # server expects after every fresh connection.
      def welcome
        @write_mutex.synchronize do
          identifiers = @mutex.synchronize do
            @attempts = 0
            @welcomed = true
            @reconnected = @ever_welcomed
            @ever_welcomed = true
            @subscriptions.each_value(&:pending!)
            @changed.broadcast

            @subscriptions.keys
          end

          resubscribe(identifiers)
        end
      end

      # Resends subscribe commands until they are confirmed. A subscribe sent
      # while the server was still setting the connection up is simply dropped
      # on the floor, so unconfirmed means unheard.
      def guarantee_subscriptions(stopper)
        loop do
          stopper.pop(timeout: @subscribe_retry)
          break if stopper.closed?

          @write_mutex.synchronize { resubscribe(pending_identifiers) }
        end
      end

      # Sends a subscribe for each identifier. The caller holds the write lock
      # from before the identifiers were listed until this returns, so nothing
      # else can get a command out in between. Otherwise an unsubscribe that
      # lands mid-list could write itself ahead of the subscribe for the same
      # identifier, and the server would end up holding a subscription nobody
      # here knows about — one it would silently ignore every later subscribe
      # for.
      def resubscribe(identifiers)
        identifiers.each do |identifier|
          write(Protocol::Command.new(name: :subscribe, identifier: identifier))
        rescue StandardError => error
          @logger.warn("actioncable: resubscribing to #{identifier}: #{error.message}")
        end
      end

      def pending_identifiers
        @mutex.synchronize do
          @subscriptions.select { |_, registration| registration.pending }.keys
        end
      end

      def confirm(identifier)
        holders, reconnected = @mutex.synchronize do
          registration = @subscriptions[identifier]

          # Only an identifier waiting on a verdict has news. The server can
          # confirm twice when a retried subscribe crosses the first
          # confirmation.
          if registration.nil? || !registration.pending
            [ [], false ]
          else
            registration.pending = false
            registration.confirmed = true
            [ registration.holders, @reconnected ]
          end
        end

        holders.each { |subscription| subscription.confirm(reconnected) }
      end

      def reject(identifier)
        holders = @mutex.synchronize do
          registration = @subscriptions.delete(identifier)
          registration ? registration.holders : []
        end

        holders.each(&:reject)
      end

      def deliver(incoming)
        holders = @mutex.synchronize { holders_of(incoming.identifier) }

        if holders.empty?
          @logger.warn("actioncable: no subscription for #{incoming.identifier}, dropping message")
          return
        end

        holders.each do |subscription|
          unless subscription.deliver(incoming.message)
            @logger.warn("actioncable: message buffer full for #{incoming.identifier}, dropping message")
          end
        end
      end

      def hang_up(incoming)
        hangup = DisconnectError.new(reason: incoming.reason, reconnect: incoming.reconnect?)

        if incoming.reconnect?
          raise hangup
        else
          stop_and_raise hangup
        end
      end

      # Tears the current connection down and tells every subscription.
      def disconnect
        subscriptions, will_reconnect = @mutex.synchronize do
          @connection = nil
          @protocol = nil
          @welcomed = false
          @subscriptions.each_value(&:reset)
          @changed.broadcast

          [ all_subscriptions, !@stopped ]
        end

        subscriptions.each { |subscription| subscription.disconnect(will_reconnect) }
      end

      # Puts one command on the connection. The caller holds the write lock.
      def write(command, timeout: nil)
        connection, protocol, welcomed = @mutex.synchronize { [ @connection, @protocol, @welcomed ] }

        # Before the welcome the server hasn't finished setting the connection
        # up and throws away whatever it receives, so there is nowhere to send
        # yet.
        raise NotConnectedError unless connection && welcomed

        connection.write(protocol.encode(command), timeout: timeout)
      end

      def enroll(key, on_connected:, on_disconnected:, on_rejected:)
        @mutex.synchronize do
          raise failure_locked if @stopped
          raise NotConnectedError if @thread.nil?

          subscription = Subscription.new(self, key, @message_buffer, @logger,
            on_connected: on_connected, on_disconnected: on_disconnected, on_rejected: on_rejected)

          registration = @subscriptions[key]
          shared = !registration.nil?
          registration ||= @subscriptions[key] = Registration.new
          registration.holders << subscription

          [ subscription, registration.confirmed, shared ]
        end
      end

      def announce_subscribe(key)
        send_command(Protocol::Command.new(name: :subscribe, identifier: key))
      rescue StandardError => error
        # Nothing to do about it here: the connection will subscribe again as
        # soon as it is welcomed back.
        @logger.warn("actioncable: subscribing to #{key}: #{error.message}")
      end

      def await_verdict(subscription, key, deadline)
        confirmed, rejected, failure = @mutex.synchronize do
          wait_until(deadline) { subscription.settled? || @stopped }
          [ subscription.confirmed, subscription.rejected, @stopped ? failure_locked : nil ]
        end

        if confirmed
          subscription
        elsif rejected
          refuse(subscription, RejectedError.new(key))
        elsif failure
          refuse(subscription, failure)
        else
          abandon(subscription, TimeoutError.new("timed out waiting for #{key} to be confirmed"))
        end
      end

      def refuse(subscription, reason)
        forget(subscription, reason)
        raise reason
      end

      # Forgets a subscription its caller gave up waiting on. When it was the
      # last holder of an identifier the server has heard a subscribe for, the
      # server is told to let go, or it would keep the subscription and ignore
      # the next subscribe for it as a duplicate. The connection may well be
      # gone by now, and then there is nothing to tell.
      #
      # The unsubscribe is sent before raising rather than in the background so
      # a subscribe for the same identifier that follows can't get ahead of it.
      def abandon(subscription, reason)
        last, heard = forget(subscription, reason)

        if last && heard
          begin
            send_command(Protocol::Command.new(name: :unsubscribe, identifier: subscription.key))
          rescue StandardError => error
            @logger.warn("actioncable: letting go of #{subscription.key}: #{error.message}")
          end
        end

        raise reason
      end

      def close_subscriptions
        subscriptions, failure = @mutex.synchronize do
          all = all_subscriptions
          @subscriptions = {}

          [ all, failure_locked ]
        end

        subscriptions.each { |subscription| subscription.close(failure) }
      end

      def holders_of(identifier)
        registration = @subscriptions[identifier]
        registration ? registration.holders : []
      end

      def all_subscriptions
        @subscriptions.each_value.flat_map(&:holders)
      end

      # Shuts the client down for good: some failures don't get better by
      # dialing again.
      def stop_and_raise(reason)
        stop_with(reason)
        raise reason
      end

      def stop_with(reason)
        @mutex.synchronize { mark_stopped(reason) }
      end

      # Marks the client stopped for the reason given, unless an earlier reason
      # already stands. The caller holds the lock.
      def mark_stopped(reason)
        @stopped = true
        @failure ||= reason
        @changed.broadcast
      end

      # Hangs up whatever connection a stopped client still has open and waits
      # until nothing is running any more. Reports why it stopped.
      def await_stopped
        failure, thread, connection = @mutex.synchronize { [ @failure, @thread, @connection ] }

        if thread.nil?
          # Nothing was ever started, so nothing will finish it for us.
          finish
          return failure
        end

        connection&.close
        thread.join unless thread == Thread.current

        failure
      end

      def finish
        @mutex.synchronize do
          @finished = true
          @changed.broadcast
        end
      end

      def failure_locked
        @failure || ClosedError.new
      end

      # Records one more failed attempt, and what failed it, and reports how
      # many have failed in a row.
      def count_attempt(error)
        @mutex.synchronize do
          @attempts += 1
          @last_error = error
          @attempts
        end
      end

      def wait_before_retry
        deadline = Deadline.in(reconnect_delay)

        @mutex.synchronize do
          wait_until(deadline) { @stopped }
          !@stopped
        end
      end

      # Doubles the delay per failed attempt, up to the longest, and spreads the
      # result over the last interval so a restarted server doesn't get every
      # client back at the same instant.
      def reconnect_delay
        attempts = @mutex.synchronize { @attempts }
        doublings = [ [ attempts - 1, 0 ].max, 16 ].min
        delay = [ @initial_backoff * (2**doublings), @longest_backoff ].min

        delay / 2 + (rand * delay / 2)
      end

      # Waits for the block to hold, or for the deadline to run out. The caller
      # holds the lock, which the wait releases while it sleeps.
      def wait_until(deadline)
        until yield
          remaining = deadline.remaining
          break if remaining&.zero?

          @changed.wait(@mutex, remaining)
        end
      end
  end
end
