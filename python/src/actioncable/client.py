"""One connection to an Action Cable server, and the subscriptions on it."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import random
from collections.abc import Awaitable, Callable, Mapping, Sequence
from inspect import isawaitable
from urllib.parse import urlsplit

from ._events import first_of
from .errors import (
    ActionCableError,
    AlreadyConnectedError,
    ClosedError,
    DisconnectError,
    GaveUpError,
    NoProtocolsError,
    NotConnectedError,
    UnsupportedSubprotocolError,
)
from .headers import Headers
from .identifier import Identifier
from .protocol import (
    SUBPROTOCOL_UNSUPPORTED,
    Command,
    CommandName,
    Incoming,
    Kind,
    Protocol,
)
from .subscription import (
    OnConnected,
    OnDisconnected,
    OnRejected,
    Registration,
    Subscription,
)
from .transport import Conn, DialOptions, Transport
from .v1_json import V1JSON
from .websocket import WebSocketTransport

HeadersFunc = Callable[[], Mapping[str, str] | Awaitable[Mapping[str, str]]]
StopOnError = Callable[[BaseException], bool]

_LOGGER = logging.getLogger("actioncable")
_LOGGER.addHandler(logging.NullHandler())


class Client:
    """Owns one connection to an Action Cable server and the subscriptions
    running over it.

    Build one, start it with :meth:`connect`, and hang up with :meth:`close`.
    Everything here runs on one event loop, which is what Go's client needs a
    mutex for: state only changes between awaits, so there is nothing to guard
    but the order commands leave in.
    """

    def __init__(
        self,
        url: str,
        *,
        transport: Transport | None = None,
        protocols: Sequence[Protocol] | None = None,
        additional_protocols: Sequence[Protocol] = (),
        headers: Mapping[str, str] | None = None,
        headers_func: HeadersFunc | None = None,
        cookie: str | None = None,
        origin: str | None = None,
        logger: logging.Logger | None = None,
        stale_after: float = 6.0,
        backoff: tuple[float, float] = (1.0, 30.0),
        max_attempts: int | None = None,
        subscribe_retry: float = 0.5,
        message_buffer: int = 64,
        stop_on_error: StopOnError | None = None,
    ) -> None:
        self._url = url
        self._transport = transport if transport is not None else WebSocketTransport()
        self._protocols = list(additional_protocols) + (list(protocols) if protocols is not None else [V1JSON()])
        self._headers = Headers(headers)
        self._headers_func = headers_func
        self._stop_on_error = stop_on_error
        self._logger = logger if logger is not None else _LOGGER

        self._stale_after = stale_after
        self._subscribe_retry = subscribe_retry
        self._initial_backoff, self._longest_backoff = backoff
        self._max_attempts = max_attempts
        self._message_buffer = message_buffer

        if cookie is not None:
            self._headers["Cookie"] = cookie
        if origin is not None:
            self._headers["Origin"] = origin
        self._assume_origin()

        self._conn: Conn | None = None
        self._protocol: Protocol | None = None
        self._subscriptions: dict[str, Registration] = {}
        self._attempts = 0
        # The failure of the latest attempt, kept so a connect that gives up
        # waiting can say what it was waiting on.
        self._last_error: BaseException | None = None
        self._reconnected = False
        self._welcomed = False
        self._ever_welcomed = False
        self._stopped = False
        self._failure: BaseException | None = None
        self._task: asyncio.Task[None] | None = None

        # Commands go out one at a time, and a resubscribe holds this for the
        # whole list, so nothing can slip between two of them.
        self._write_lock = asyncio.Lock()
        self._connected = asyncio.Event()
        self._done = asyncio.Event()

    def _assume_origin(self) -> None:
        """Fill in an Origin for the opening request when none was given.

        Rails compares Origin against the host it serves on and turns down
        anything else, a request carrying no Origin at all included, so the
        Action Cable URL's own origin is the one that gets in. A server behind
        a proxy that terminates TLS sees a different scheme than the URL says,
        and needs ``origin=`` to say so.
        """
        if self._headers.get("Origin"):
            return

        assumed = _origin_of(self._url)
        if assumed:
            self._headers["Origin"] = assumed

    async def connect(self, *, timeout: float | None = None) -> None:
        """Start the client and return once the server has sent its welcome.

        Failed attempts are retried until that happens, ``timeout`` runs out,
        the task awaiting this is cancelled, the server tells us not to come
        back, or ``stop_on_error`` recognizes a failure as terminal.

        ``timeout`` bounds the wait, not a connection that got through: that
        lives until :meth:`close`. A ``connect`` that raises leaves the client
        stopped, with nothing running behind it, so a client that failed to
        connect is one to throw away. The one exception is
        :class:`~actioncable.errors.AlreadyConnectedError`, which says the
        client was running fine before the call and still is.
        """
        if self._stopped:
            raise self._failure_or_closed()
        if self._task is not None:
            raise AlreadyConnectedError()

        self._task = asyncio.create_task(self._run(), name="actioncable-connection")

        try:
            async with asyncio.timeout(timeout):
                await first_of(self._connected, self._done)
        except TimeoutError as expiry:
            await self._give_up_waiting(expiry)
            return
        except asyncio.CancelledError as cancellation:
            self._stop(cancellation)
            self._task.cancel()
            raise

        if not self._connected.is_set():
            raise self._stopped_because()

    async def _give_up_waiting(self, expiry: TimeoutError) -> None:
        """Stop a client whose connect ran out of time, unless the welcome
        landed in the same instant, in which case the connection is kept."""
        if self._ever_welcomed:
            return

        timed_out = TimeoutError("timed out waiting for the welcome")
        timed_out.__cause__ = expiry
        self._stop(self._explain(timed_out))
        await self._await_stopped()

        raise self._failure_or_closed()

    @property
    def connected(self) -> bool:
        """Whether a connection is up and welcomed."""
        return self._welcomed and self._conn is not None

    async def done(self) -> None:
        """Wait until the client has stopped for good — closed, told by the
        server not to come back, out of attempts, or unable to connect in the
        first place — and will neither reconnect nor deliver anything more.
        :attr:`error` says why."""
        await self._done.wait()

    @property
    def error(self) -> BaseException | None:
        """Why the client stopped, and ``None`` while it is still running or
        has yet to be started."""
        if self._stopped:
            return self._failure_or_closed()
        else:
            return None

    async def subscribe(
        self,
        identifier: Identifier,
        *,
        on_connected: OnConnected | None = None,
        on_disconnected: OnDisconnected | None = None,
        on_rejected: OnRejected | None = None,
        timeout: float | None = None,
    ) -> Subscription:
        """Subscribe to a channel and return once the server confirms it.

        The subscription outlives reconnects — it is resubscribed
        automatically — so it stays valid until
        :meth:`~actioncable.subscription.Subscription.unsubscribe`.

        Subscribing to an identifier the client already holds shares the
        server's one subscription for it instead of asking for another, which
        Rails would ignore. Every subscription sharing an identifier gets every
        message, and the server hears unsubscribe from the last one to go.

        It raises :class:`~actioncable.errors.RejectedError` when the channel
        turns the subscription down.
        """
        key = identifier.key

        if self._stopped:
            raise self._failure_or_closed()
        if self._task is None:
            raise NotConnectedError()

        subscription = Subscription(
            self,
            key,
            self._message_buffer,
            self._logger,
            on_connected=on_connected,
            on_disconnected=on_disconnected,
            on_rejected=on_rejected,
        )
        registration = self._subscriptions.get(key)
        shared = registration is not None
        if registration is None:
            registration = Registration()
            self._subscriptions[key] = registration
        registration.holders.append(subscription)

        if registration.confirmed:
            # The server said yes to this identifier on the connection in hand
            # and won't say so again, so the new holder is as confirmed as the
            # rest.
            subscription._confirm(False)
            return subscription

        # A shared identifier's subscribe is already out, or goes out with the
        # next welcome, and its verdict is this subscription's too.
        if not shared:
            try:
                await self._send(Command(CommandName.SUBSCRIBE, key))
            except ActionCableError as error:
                # Nothing to do about it here: the connection will subscribe
                # again as soon as it is welcomed back.
                self._logger.info("subscribing to %s: %s", key, error)

        return await self._await_verdict(subscription, timeout)

    async def _await_verdict(self, subscription: Subscription, timeout: float | None) -> Subscription:
        try:
            async with asyncio.timeout(timeout):
                await first_of(subscription._confirmed, subscription._rejected, self._done)
        except TimeoutError as expiry:
            await self._abandon(subscription, expiry)
            raise
        except asyncio.CancelledError as cancellation:
            await self._abandon(subscription, cancellation)
            raise

        if subscription._confirmed.is_set():
            return subscription

        if subscription._rejected.is_set():
            rejection = subscription._rejection()
            self._forget(subscription, rejection)
            raise rejection

        failure = self._stopped_because()
        self._forget(subscription, failure)
        raise failure

    async def _abandon(self, subscription: Subscription, reason: BaseException) -> None:
        """Forget a subscription its caller gave up waiting on.

        When it was the last holder of an identifier the server has heard a
        subscribe for, the server is told to let go, or it would keep the
        subscription and ignore the next subscribe for it as a duplicate. The
        connection may well be gone by now, and then there is nothing to tell.

        The unsubscribe is sent before returning rather than in the background
        so a subscribe for the same identifier that follows can't get ahead
        of it.
        """
        last, heard = self._forget(subscription, reason)

        if last and heard:
            with contextlib.suppress(ActionCableError):
                await self._send(Command(CommandName.UNSUBSCRIBE, subscription.key))

    async def close(self) -> None:
        """Hang up, stop reconnecting, and end every subscription's message
        iterator. Safe to call from a subscription callback, and safe to call
        twice."""
        await self._shutdown(ClosedError())

    async def _shutdown(self, reason: BaseException) -> None:
        """Stop the client for the reason given, hang up whatever connection is
        open, and wait for the connection task to finish.

        Subscription callbacks still queued run on their own tasks after that,
        and each subscription's messages end once its last one has.
        """
        self._stop(reason)
        await self._await_stopped()

    async def _await_stopped(self) -> None:
        """Hang up whatever connection a stopped client still has open and wait
        until nothing is running any more."""
        task, conn = self._task, self._conn

        if task is None:
            # Nothing was ever started, so nothing will finish it for us.
            self._finish()
            return

        task.cancel()
        if conn is not None:
            await conn.close()
        await self._done.wait()

    async def _run(self) -> None:
        try:
            while True:
                await self._session()
                if self._stopped:
                    return
                await asyncio.sleep(self._reconnect_delay())
        finally:
            self._close_subscriptions()
            self._finish()

    async def _session(self) -> None:
        """Run one connection from dial to hangup."""
        if not self._protocols:
            self._stop(NoProtocolsError())
            return

        conn = await self._dial()
        if conn is None:
            return

        try:
            protocol = self._negotiated(conn.subprotocol)
        except UnsupportedSubprotocolError as unsupported:
            self._stop(unsupported)
            await conn.close()
            return

        self._conn, self._protocol = conn, protocol
        guarantor = asyncio.create_task(self._guarantee_subscriptions(), name="actioncable-guarantor")
        try:
            await self._receive(conn, protocol)
        except Exception as error:
            # Ahead of the teardown below, so the subscriptions hear that the
            # client is not coming back rather than that it is.
            self._failed(error)
            if not self._stopped:
                self._logger.info("connection to %s ended: %s", self._url, error)
        finally:
            guarantor.cancel()
            await asyncio.gather(guarantor, return_exceptions=True)
            self._disconnect()
            await conn.close()

    async def _dial(self) -> Conn | None:
        try:
            headers = await self._dial_headers()

            return await self._transport.dial(
                self._url,
                DialOptions(subprotocols=[*self._subprotocols(), SUBPROTOCOL_UNSUPPORTED], headers=headers),
            )
        except Exception as error:
            self._failed(error)
            if not self._stopped:
                self._logger.info("connecting to %s: %s", self._url, error)

            return None

    async def _dial_headers(self) -> Headers:
        """What the opening request carries.

        Without ``headers_func`` that is what was set once, at construction;
        with it, what the caller says now, laid over the headers already there.
        """
        if self._headers_func is None:
            return self._headers

        current = self._headers_func()
        if isawaitable(current):
            current = await current

        headers = self._headers.copy()
        headers.update(current)

        return headers

    def _failed(self, error: BaseException) -> None:
        """Record why an attempt ended and, when that was the last one allowed,
        stop the client."""
        if self._stopped:
            return

        if self._stop_on_error is not None and self._stop_on_error(error):
            self._stop(error)
            return

        self._attempts += 1
        self._last_error = error
        if self._attempts == self._max_attempts:
            self._stop(self._explain(GaveUpError()))

    def _subprotocols(self) -> list[str]:
        """Every protocol the client can speak, most preferred first."""
        return [protocol.subprotocol for protocol in self._protocols]

    def _negotiated(self, subprotocol: str) -> Protocol:
        """The protocol the server picked out of the ones offered.

        A server that picks the sentinel, names something never offered, or
        names nothing at all leaves nothing to talk over, and dialing again
        won't change it.
        """
        for protocol in self._protocols:
            if protocol.subprotocol == subprotocol:
                return protocol

        if subprotocol == SUBPROTOCOL_UNSUPPORTED:
            offered = ", ".join(self._subprotocols())
            raise UnsupportedSubprotocolError(f"unsupported subprotocol: the server speaks none of {offered}")
        else:
            raise UnsupportedSubprotocolError(f"unsupported subprotocol: {subprotocol!r}")

    async def _receive(self, conn: Conn, protocol: Protocol) -> None:
        """Read until the connection dies.

        A connection that has gone quiet for longer than ``stale_after`` is
        dead: the server beats a ping every three seconds.
        """
        while True:
            try:
                async with asyncio.timeout(self._stale_after):
                    payload = await conn.read()
            except TimeoutError as expiry:
                # asyncio re-raises a cancellation as itself, so a TimeoutError
                # here is our own staleness deadline and never the caller's.
                raise ActionCableError(f"no frame in {self._stale_after}s") from expiry

            await self._dispatch(protocol, payload)

    async def _dispatch(self, protocol: Protocol, payload: bytes) -> None:
        try:
            incoming = protocol.decode(payload)
        except ActionCableError as error:
            self._logger.info("dropping undecodable frame: %s", error)
            return

        if incoming.kind is Kind.WELCOME:
            await self._welcome()
        elif incoming.kind is Kind.PING:
            # The frame itself is the heartbeat, and reading it already reset
            # the staleness deadline.
            pass
        elif incoming.kind is Kind.DISCONNECT:
            self._hang_up(incoming)
        elif incoming.kind is Kind.CONFIRMATION:
            self._confirm(incoming.identifier)
        elif incoming.kind is Kind.REJECTION:
            self._reject(incoming.identifier)
        elif incoming.kind is Kind.MESSAGE:
            self._deliver(incoming)

    async def _welcome(self) -> None:
        """Reset the connection's health and resubscribe everything, the way
        the server expects after every fresh connection."""
        async with self._write_lock:
            self._attempts = 0
            self._welcomed = True
            self._reconnected = self._ever_welcomed
            self._ever_welcomed = True
            for registration in self._subscriptions.values():
                registration.pending, registration.confirmed = True, False
            identifiers = list(self._subscriptions)

            self._connected.set()

            await self._resubscribe(identifiers)

    async def _guarantee_subscriptions(self) -> None:
        """Resend subscribe commands until they are confirmed.

        A subscribe sent while the server was still setting the connection up
        is simply dropped on the floor, so unconfirmed means unheard.
        """
        while True:
            await asyncio.sleep(self._subscribe_retry)

            async with self._write_lock:
                await self._resubscribe(self._pending_identifiers())

    async def _resubscribe(self, identifiers: Sequence[str]) -> None:
        """Send a subscribe for each identifier.

        The caller holds the write lock from before the identifiers were listed
        until this returns, so nothing else can get a command out in between.
        Otherwise an unsubscribe that lands mid-list could write its
        unsubscribe ahead of the subscribe for the same identifier, and the
        server would end up holding a subscription nobody here knows about —
        one it would silently ignore every later subscribe for.
        """
        for identifier in identifiers:
            try:
                await self._write(Command(CommandName.SUBSCRIBE, identifier))
            except ActionCableError as error:
                self._logger.info("resubscribing to %s: %s", identifier, error)

    def _confirm(self, identifier: str) -> None:
        registration = self._subscriptions.get(identifier)
        # Only an identifier waiting on a verdict has news. The server can
        # confirm twice when a retried subscribe crosses the first confirmation.
        if registration is None or not registration.pending:
            return

        registration.pending, registration.confirmed = False, True
        for subscription in list(registration.holders):
            subscription._confirm(self._reconnected)

    def _reject(self, identifier: str) -> None:
        holders = self._holders(identifier)
        self._subscriptions.pop(identifier, None)

        for subscription in holders:
            subscription._reject()

    def _deliver(self, incoming: Incoming) -> None:
        subscriptions = self._holders(incoming.identifier)

        if not subscriptions:
            self._logger.info("no subscription for %s, dropping message", incoming.identifier)
            return

        for subscription in subscriptions:
            if not subscription._deliver(incoming.message):
                self._logger.info("message buffer full for %s, dropping message", incoming.identifier)

    def _hang_up(self, incoming: Incoming) -> None:
        disconnect = DisconnectError(incoming.reason, incoming.reconnect)

        if not incoming.reconnect:
            self._stop(disconnect)

        raise disconnect

    def _disconnect(self) -> None:
        """Tear down the current connection and tell every subscription."""
        self._conn = None
        self._protocol = None
        self._welcomed = False
        for registration in self._subscriptions.values():
            registration.pending, registration.confirmed = False, False
        will_reconnect = not self._stopped

        for subscription in self._all_subscriptions():
            subscription._disconnect(will_reconnect)

    async def _send(self, command: Command) -> None:
        async with self._write_lock:
            await self._write(command)

    async def _write(self, command: Command) -> None:
        """Put one command on the connection. The caller holds the write lock."""
        # Before the welcome the server hasn't finished setting the connection
        # up and throws away whatever it receives, so there is nowhere to send
        # yet.
        if self._conn is None or self._protocol is None or not self._welcomed:
            raise NotConnectedError()

        try:
            payload = self._protocol.encode(command)
        except Exception as error:
            raise ActionCableError(f"encoding {command.name} command: {error}") from error

        await self._conn.write(payload)

    def _forget(self, subscription: Subscription, reason: BaseException) -> tuple[bool, bool]:
        """Drop a subscription, reporting whether it was the last one holding
        that identifier — which is when the server needs to hear about it — and
        whether the server has heard a subscribe for it on the connection in
        hand at all."""
        remaining = [holder for holder in self._holders(subscription.key) if holder is not subscription]
        last = not remaining

        registration = self._subscriptions.get(subscription.key)
        heard = registration is not None and (registration.pending or registration.confirmed)

        if last:
            self._subscriptions.pop(subscription.key, None)
        elif registration is not None:
            registration.holders = remaining

        subscription._close(reason)

        return last, heard

    def _close_subscriptions(self) -> None:
        subscriptions = self._all_subscriptions()
        self._subscriptions = {}
        failure = self._failure_or_closed()

        for subscription in subscriptions:
            subscription._close(failure)

    def _holders(self, identifier: str) -> list[Subscription]:
        registration = self._subscriptions.get(identifier)

        if registration is None:
            return []
        else:
            return list(registration.holders)

    def _all_subscriptions(self) -> list[Subscription]:
        return [holder for registration in self._subscriptions.values() for holder in registration.holders]

    def _pending_identifiers(self) -> list[str]:
        return [identifier for identifier, held in self._subscriptions.items() if held.pending]

    def _stop(self, reason: BaseException) -> None:
        """Shut the client down for good: some failures don't get better by
        dialing again.

        It only marks. Go cancels the connection's context here, which leaves
        its deferred teardown to run; cancelling an asyncio task would
        interrupt that teardown mid-way, and a client that stops itself is
        always inside the task anyway, where the loop reads this on its next
        turn. Stopping a client from outside is
        :meth:`_await_stopped`'s business, and that one does cancel.
        """
        self._stopped = True
        if self._failure is None:
            self._failure = reason

    def _finish(self) -> None:
        self._done.set()

    def _stopped_because(self) -> BaseException:
        return self._failure_or_closed()

    def _failure_or_closed(self) -> BaseException:
        if self._failure is not None:
            return self._failure
        else:
            return ClosedError()

    def _explain(self, error: GaveUpError | TimeoutError) -> BaseException:
        """Pair an error about giving up with the failure that was being waited
        out, so a deadline that ran out on bad credentials says so."""
        if self._last_error is None:
            return error

        explained = type(error)(f"{error} (last attempt: {self._last_error})")
        explained.__cause__ = self._last_error

        return explained

    def _reconnect_delay(self) -> float:
        """Double the delay per failed attempt, up to the longest, and spread
        the result over the last interval so a restarted server doesn't get
        every client back at the same instant."""
        doubled = self._initial_backoff * 2 ** min(max(self._attempts - 1, 0), 16)
        delay = min(doubled, self._longest_backoff)

        # Spreading reconnects is not a secret, so the fast generator is the
        # right one.
        return delay / 2 + random.random() * delay / 2  # noqa: S311


def _origin_of(url: str) -> str:
    endpoint = urlsplit(url)

    if endpoint.scheme.lower() in ("wss", "https"):
        return "https://" + endpoint.netloc
    elif endpoint.scheme.lower() in ("ws", "http"):
        return "http://" + endpoint.netloc
    else:
        return ""
