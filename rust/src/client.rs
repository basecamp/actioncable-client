use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::convert::Infallible;
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use http::HeaderMap;
use tokio::sync::watch;

use crate::builder::{ClientBuilder, Config};
use crate::error::Error;
use crate::protocol::{Command, Incoming, Kind, Protocol, SUBPROTOCOL_UNSUPPORTED};
use crate::subscription::{Decision, Receivers, Registration, SubscribeRequest, Subscription};
use crate::transport::{Conn, DialOptions};

/// One connection to an Action Cable server and the subscriptions running over it. Build
/// one with [`builder`](Client::builder), start it with [`connect`](Client::connect), and
/// hang up with [`close`](Client::close). Handles are cheap to clone and share the
/// connection.
///
/// The connection lives until `close`, not until the last handle is dropped: a client that
/// is never closed keeps reconnecting.
#[derive(Clone)]
pub struct Client {
    inner: Arc<Inner>,
}

impl Client {
    /// A client for an Action Cable endpoint, typically `wss://host/cable`. It speaks over
    /// the built-in WebSocket transport unless [`ClientBuilder::transport`] says otherwise.
    pub fn builder(url: impl Into<String>) -> ClientBuilder {
        ClientBuilder::new(url.into())
    }

    pub(crate) fn new(config: Config) -> Client {
        Client {
            inner: Arc::new(Inner {
                config,
                state: Mutex::new(State::default()),
                write_lock: tokio::sync::Mutex::new(()),
                connected: watch::Sender::new(false),
                stopping: watch::Sender::new(false),
                done: watch::Sender::new(false),
            }),
        }
    }

    /// Starts the client and returns once the server has sent its welcome. Failed attempts
    /// are retried until that happens, the server tells us not to come back, or the
    /// attempts run out, so wrap the call in [`tokio::time::timeout`] for a deadline.
    ///
    /// Dropping the future bounds the wait, not the client: where the Go client stops on a
    /// context that ends, this one keeps dialing until [`close`](Client::close), because a
    /// dropped future is how a `select!` loses a race and killing the connection over that
    /// would surprise everyone. A caller that has given up should `close`, and
    /// [`last_error`](Client::last_error) says what the client was waiting out.
    ///
    /// Returns [`Error::AlreadyConnected`] on a client that is already running, and on one
    /// that has stopped, whatever stopped it.
    pub async fn connect(&self) -> Result<(), Error> {
        self.inner.state().start()?;

        tokio::spawn(Arc::clone(&self.inner).run());

        let mut connected = self.inner.connected.subscribe();
        let mut done = self.inner.done.subscribe();
        tokio::select! {
            biased;
            _ = connected.wait_for(|connected| *connected) => Ok(()),
            _ = done.wait_for(|done| *done) => Err(self.inner.state().failure_or_closed()),
        }
    }

    /// Whether a connection is up and welcomed.
    pub fn connected(&self) -> bool {
        let state = self.inner.state();
        state.welcomed && state.conn.is_some()
    }

    /// Waits until the client has stopped for good — closed, told by the server not to come
    /// back, out of attempts, or stopped by
    /// [`stop_on_error`](ClientBuilder::stop_on_error) — and will neither reconnect nor
    /// deliver anything more. [`err`](Client::err) says why. Where the Go client hands out a
    /// `Done()` channel, here the wait is the future itself.
    pub async fn done(&self) {
        let mut done = self.inner.done.subscribe();
        let _stopped = done.wait_for(|done| *done).await;
    }

    /// Why the client stopped, and `None` while it is still running or has yet to be
    /// started.
    pub fn err(&self) -> Option<Error> {
        let state = self.inner.state();
        if state.stopped {
            Some(state.failure_or_closed())
        } else {
            None
        }
    }

    /// Why the last connection attempt failed, whether or not the client is still trying.
    /// It is what a `connect` that ran out of patience was waiting out, so a credential
    /// that can't be built doesn't hide behind a deadline. `None` until an attempt fails.
    pub fn last_error(&self) -> Option<Error> {
        self.inner.state().last_error.clone()
    }

    /// Subscribes to a channel and returns once the server confirms it. Takes an
    /// [`Identifier`](crate::Identifier), or a [`SubscribeRequest`] when there are
    /// callbacks to attach. The subscription outlives reconnects, resubscribed
    /// automatically, so it stays valid until [`Subscription::unsubscribe`].
    ///
    /// Subscribing to an identifier the client already holds joins the existing
    /// subscription rather than asking the server again, which Rails would ignore: a
    /// confirmed one confirms the new handle at once, and one still waiting shares its
    /// verdict with the new handle.
    ///
    /// Returns [`Error::Rejected`] when the channel turns the subscription down, and
    /// [`Error::NotConnected`] before [`connect`](Client::connect). Dropping the future, from
    /// a [`tokio::time::timeout`] say, forgets the subscription and, when nothing else holds
    /// the identifier, tells the server to drop it too; a confirmation that arrives later
    /// goes nowhere.
    pub async fn subscribe(
        &self,
        request: impl Into<SubscribeRequest>,
    ) -> Result<Subscription, Error> {
        let (identifier, callbacks) = request.into().into_parts();
        let key = identifier.key();
        let (registration, mut receivers, joined) = self
            .inner
            .state()
            .register(key.clone(), self.inner.config.message_buffer)?;
        let mut forgetting = Forgetting::new(Arc::clone(&self.inner), Arc::clone(&registration));
        let running = callbacks.spawn(registration.watch_events());

        match joined {
            Joined::New => self.inner.send_subscribe(&key).await,
            Joined::Pending => {}
            Joined::Confirmed { reconnected } => registration.confirm(reconnected),
        }

        let mut done = self.inner.done.subscribe();
        let verdict = tokio::select! {
            biased;
            decision = &mut receivers.decision => decision.ok(),
            _ = done.wait_for(|done| *done) => None,
        };

        match verdict {
            Some(Decision::Confirmed) => {
                forgetting.disarm();
                Ok(Subscription::new(
                    Arc::downgrade(&self.inner),
                    registration,
                    receivers,
                    running,
                ))
            }
            Some(Decision::Rejected) => {
                forgetting.disarm();
                Err(Error::Rejected { key })
            }
            None => Err(self.inner.state().failure_or_closed()),
        }
    }

    /// Hangs up, stops reconnecting, and ends every subscription's streams. Safe to call
    /// twice, and final: `connect` afterwards returns [`Error::Closed`].
    pub async fn close(&self) {
        let started = {
            let mut state = self.inner.state();
            state.stopped = true;
            state.failure.get_or_insert(Error::Closed);
            state.started
        };

        if started {
            self.inner.stopping.send_replace(true);
        } else {
            self.inner.done.send_replace(true);
        }
        self.done().await;
    }
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("url", &self.inner.config.url)
            .field("connected", &self.connected())
            .finish()
    }
}

/// Forgets a subscription the server gave no verdict on when the wait for one ends any
/// other way, dropping the future included. The server may still confirm the subscribe
/// that went out, and would then ignore the next one for the identifier, so the last holder
/// to go takes it back.
struct Forgetting {
    inner: Arc<Inner>,
    registration: Arc<Registration>,
    armed: bool,
}

impl Forgetting {
    fn new(inner: Arc<Inner>, registration: Arc<Registration>) -> Forgetting {
        Forgetting {
            inner,
            registration,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for Forgetting {
    fn drop(&mut self) {
        if self.armed && self.inner.forget(&self.registration, &Error::Unsubscribed) {
            self.inner.unsubscribe_later(&self.registration.key);
        }
    }
}

pub(crate) struct Inner {
    config: Config,
    state: Mutex<State>,
    /// Serializes writes to the connection. Its own lock so a slow write doesn't hold up
    /// everything else reading the client's state.
    write_lock: tokio::sync::Mutex<()>,
    /// Flips once, at the first welcome.
    connected: watch::Sender<bool>,
    /// Flips once, when the client is told to stop.
    stopping: watch::Sender<bool>,
    /// Flips once, when the run loop has finished.
    done: watch::Sender<bool>,
}

#[derive(Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "a connection is a handful of independent facts, and an enum of their combinations would be longer than the struct"
)]
struct State {
    conn: Option<Arc<dyn Conn>>,
    /// The protocol the server picked for the connection in hand.
    protocol: Option<Arc<dyn Protocol>>,
    channels: HashMap<String, Channel>,
    attempts: u32,
    /// Why the latest attempt failed, kept so a caller that gave up waiting can say what it
    /// was waiting on.
    last_error: Option<Error>,
    reconnected: bool,
    welcomed: bool,
    ever_welcomed: bool,
    started: bool,
    stopped: bool,
    failure: Option<Error>,
    /// Whether the subscriptions have heard that the client isn't coming back, so the run
    /// loop's last word is said once.
    stop_announced: bool,
}

/// The subscription the server holds for one identifier, and every handle sharing it. Rails
/// keeps one per identifier per connection and ignores a second subscribe for it, so the
/// client asks once and fans the answer out.
struct Channel {
    confirmed: bool,
    holders: Vec<Arc<Registration>>,
}

/// A welcomed connection and the protocol it speaks, which together is what a command needs
/// to go out.
type Writer = (Arc<dyn Conn>, Arc<dyn Protocol>);

/// What a new holder found when it joined its channel, which decides what to do next: ask
/// the server, wait for an answer already asked for, or take the one it already gave.
enum Joined {
    New,
    Pending,
    Confirmed { reconnected: bool },
}

impl State {
    fn start(&mut self) -> Result<(), Error> {
        if self.stopped {
            Err(self.failure_or_closed())
        } else if self.started {
            Err(Error::AlreadyConnected)
        } else {
            self.started = true;
            Ok(())
        }
    }

    fn register(
        &mut self,
        key: String,
        buffer: usize,
    ) -> Result<(Arc<Registration>, Receivers, Joined), Error> {
        if self.stopped {
            Err(self.failure_or_closed())
        } else if self.started {
            let (registration, receivers) = Registration::register(key.clone(), buffer);
            let reconnected = self.reconnected;
            let joined = match self.channels.entry(key) {
                Entry::Occupied(mut entry) => {
                    let channel = entry.get_mut();
                    channel.holders.push(Arc::clone(&registration));
                    if channel.confirmed {
                        Joined::Confirmed { reconnected }
                    } else {
                        Joined::Pending
                    }
                }
                Entry::Vacant(entry) => {
                    entry.insert(Channel {
                        confirmed: false,
                        holders: vec![Arc::clone(&registration)],
                    });
                    Joined::New
                }
            };
            Ok((registration, receivers, joined))
        } else {
            Err(Error::NotConnected)
        }
    }

    /// The connection to write to. Before the welcome the server hasn't finished setting the
    /// connection up and throws away whatever it receives, so there is nowhere to send yet.
    fn writer(&self) -> Result<Writer, Error> {
        match (&self.conn, &self.protocol) {
            (Some(conn), Some(protocol)) if self.welcomed => {
                Ok((Arc::clone(conn), Arc::clone(protocol)))
            }
            _ => Err(Error::NotConnected),
        }
    }

    /// What stopped the client, which is `Closed` unless something went wrong first.
    fn failure_or_closed(&self) -> Error {
        self.failure.clone().unwrap_or(Error::Closed)
    }

    fn registrations(&self) -> Vec<Arc<Registration>> {
        self.channels
            .values()
            .flat_map(|channel| channel.holders.iter().cloned())
            .collect()
    }

    fn holders(&self, key: &str) -> Vec<Arc<Registration>> {
        self.channels
            .get(key)
            .map(|channel| channel.holders.clone())
            .unwrap_or_default()
    }

    /// The identifiers the server hasn't confirmed on the connection in hand.
    fn pending_keys(&self) -> Vec<String> {
        self.channels
            .iter()
            .filter(|(_, channel)| !channel.confirmed)
            .map(|(key, _)| key.clone())
            .collect()
    }

    fn unconfirm_channels(&mut self) {
        for channel in self.channels.values_mut() {
            channel.confirmed = false;
        }
    }
}

impl Inner {
    /// Sends one command over the connection in hand. A write that fails leaves the
    /// connection in doubt, so it is hung up for the reader to notice and the client to dial
    /// again.
    pub(crate) async fn send(&self, command: Command) -> Result<(), Error> {
        let _writing = self.write_lock.lock().await;
        self.write(command).await
    }

    /// Puts one command on the connection. The caller holds the write lock.
    async fn write(&self, command: Command) -> Result<(), Error> {
        let (conn, protocol) = self.state().writer()?;
        let payload = protocol.encode(&command)?;

        let written = conn.write(&payload).await;
        if let Err(error) = &written {
            tracing::debug!(%error, "write failed, hanging up for a redial");
            conn.close().await;
        }
        written
    }

    /// Drops a holder for the reason given and reports whether it was the last one on its
    /// identifier, which is when the server needs to hear about it.
    pub(crate) fn forget(&self, registration: &Arc<Registration>, reason: &Error) -> bool {
        let last = {
            let mut state = self.state();
            match state.channels.get_mut(&registration.key) {
                Some(channel) => {
                    channel
                        .holders
                        .retain(|holder| !Arc::ptr_eq(holder, registration));
                    let last = channel.holders.is_empty();
                    if last {
                        state.channels.remove(&registration.key);
                    }
                    last
                }
                None => false,
            }
        };

        registration.close(reason);
        last
    }

    /// Tells the server to drop an identifier from somewhere that can't wait for the
    /// answer: a `Drop`. Off a tokio runtime there is no way to send, and the server keeps
    /// the subscription until the connection ends.
    pub(crate) fn unsubscribe_later(self: &Arc<Inner>, key: &str) {
        match tokio::runtime::Handle::try_current() {
            Ok(runtime) => {
                let inner = Arc::clone(self);
                let key = key.to_string();
                runtime.spawn(async move {
                    if let Err(error) = inner.send(Command::unsubscribe(&key)).await {
                        tracing::debug!(%key, %error, "unsubscribing after a drop");
                    }
                });
            }
            Err(_no_runtime) => {
                tracing::warn!(%key, "dropped outside a tokio runtime; the server keeps the subscription until the connection ends");
            }
        }
    }

    async fn run(self: Arc<Inner>) {
        let mut stopping = self.stopping.subscribe();

        loop {
            let ended = tokio::select! {
                biased;
                _ = stopping.wait_for(|stopping| *stopping) => None,
                ended = self.session() => Some(ended),
            };
            self.disconnect().await;

            if let Some(error) = ended
                && !self.is_stopped()
            {
                tracing::warn!(url = %self.config.url, %error, "connection ended");
            }
            if self.is_stopped() {
                break;
            }

            tokio::select! {
                biased;
                _ = stopping.wait_for(|stopping| *stopping) => break,
                () = tokio::time::sleep(self.reconnect_delay()) => {}
            }
        }

        self.announce_stop();
        self.close_subscriptions();
        self.done.send_replace(true);
    }

    /// One connection from dial to hangup, and why it ended. The connection is torn down by
    /// the caller, so that what tells the subscriptions whether the client is coming back
    /// runs after this has settled whether it is.
    async fn session(&self) -> Error {
        if self.config.protocols.is_empty() {
            return self.stop(Error::NoProtocols);
        }

        let headers = match self.dial_headers().await {
            Ok(headers) => headers,
            Err(error) => return self.failed(error),
        };

        let dialing = self.config.transport.dial(
            &self.config.url,
            DialOptions {
                subprotocols: self.offered_subprotocols(),
                headers,
            },
        );
        let conn: Arc<dyn Conn> = match dialing.await {
            Ok(conn) => conn.into(),
            Err(error) => return self.failed(error),
        };

        let protocol = match self.negotiated(conn.subprotocol()) {
            Ok(protocol) => protocol,
            Err(error) => {
                conn.close().await;
                return self.stop(error);
            }
        };

        {
            let mut state = self.state();
            state.conn = Some(Arc::clone(&conn));
            state.protocol = Some(Arc::clone(&protocol));
        }

        let ended = tokio::select! {
            ended = self.receive(&conn, &protocol) => ended,
            never = self.guarantee_subscriptions() => match never {},
        };
        self.failed(ended)
    }

    /// Records why an attempt ended, hands it to
    /// [`stop_on_error`](ClientBuilder::stop_on_error), and stops the client when that says
    /// so or when the attempts have run out.
    fn failed(&self, error: Error) -> Error {
        if self.is_stopped() {
            return error;
        }

        if let Some(terminal) = &self.config.stop_on_error
            && terminal(&error)
        {
            return self.stop(error);
        }

        let attempts = self.count_attempt(&error);
        if attempts == self.config.max_attempts {
            self.stop(Error::GaveUp {
                attempts,
                last: Box::new(error.clone()),
            });
        }
        error
    }

    /// What the opening request carries. Without a provider that is what was set once, at
    /// construction; with one, what the provider says now, laid over the headers already
    /// there.
    async fn dial_headers(&self) -> Result<HeaderMap, Error> {
        let mut headers = self.config.headers.clone();
        if let Some(provider) = &self.config.header_provider {
            headers.extend(provider.headers().await?);
        }
        Ok(headers)
    }

    /// Every protocol the client can speak, most preferred first, then the sentinel.
    fn offered_subprotocols(&self) -> Vec<String> {
        let mut offered = self.subprotocols();
        offered.push(SUBPROTOCOL_UNSUPPORTED.to_string());
        offered
    }

    fn subprotocols(&self) -> Vec<String> {
        self.config
            .protocols
            .iter()
            .map(|protocol| protocol.subprotocol().to_string())
            .collect()
    }

    /// The protocol the server picked out of the ones offered. A server that picks the
    /// sentinel, names something never offered, or names nothing at all leaves nothing to
    /// talk over, and dialing again won't change it.
    fn negotiated(&self, subprotocol: Option<&str>) -> Result<Arc<dyn Protocol>, Error> {
        let negotiated = subprotocol.unwrap_or_default();
        match self
            .config
            .protocols
            .iter()
            .find(|protocol| protocol.subprotocol() == negotiated)
        {
            Some(protocol) => Ok(Arc::clone(protocol)),
            None => Err(Error::UnsupportedSubprotocol {
                negotiated: negotiated.to_string(),
                offered: self.subprotocols(),
            }),
        }
    }

    /// Reads until the connection dies. A connection that has gone quiet for longer than
    /// `stale_after` is dead: the server beats a ping every three seconds.
    async fn receive(&self, conn: &Arc<dyn Conn>, protocol: &Arc<dyn Protocol>) -> Error {
        loop {
            let read = tokio::time::timeout(self.config.stale_after, conn.read()).await;
            let payload = match read {
                Ok(Ok(payload)) => payload,
                Ok(Err(error)) => return error,
                Err(_elapsed) => {
                    return Error::Stale {
                        after: self.config.stale_after,
                    };
                }
            };

            match protocol.decode(&payload) {
                Ok(incoming) => {
                    if let Some(ended) = self.dispatch(incoming).await {
                        return ended;
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "dropping undecodable frame");
                }
            }
        }
    }

    /// Acts on one frame, and reports the end of the connection when that is what it was.
    async fn dispatch(&self, incoming: Incoming) -> Option<Error> {
        match incoming.kind {
            Kind::Welcome => {
                self.welcome().await;
                None
            }
            // The frame itself is the heartbeat, and reading it already reset the staleness
            // deadline.
            Kind::Ping => None,
            Kind::Disconnect => Some(self.hang_up(incoming)),
            Kind::Confirmation => {
                self.confirm(&incoming.identifier);
                None
            }
            Kind::Rejection => {
                self.reject(&incoming.identifier);
                None
            }
            Kind::Message => {
                self.deliver(incoming);
                None
            }
        }
    }

    /// Resets the connection's health and resubscribes everything, once per identifier, the
    /// way the server expects after every fresh connection.
    async fn welcome(&self) {
        let _writing = self.write_lock.lock().await;
        let keys = {
            let mut state = self.state();
            state.attempts = 0;
            state.welcomed = true;
            state.reconnected = state.ever_welcomed;
            state.ever_welcomed = true;
            state.unconfirm_channels();
            state.pending_keys()
        };

        self.connected.send_replace(true);

        self.write_subscribes(keys).await;
    }

    /// Resends subscribe commands until they are confirmed. A subscribe sent while the
    /// server was still setting the connection up is simply dropped on the floor, so
    /// unconfirmed means unheard.
    async fn guarantee_subscriptions(&self) -> Infallible {
        loop {
            tokio::time::sleep(self.config.subscribe_retry).await;

            let _writing = self.write_lock.lock().await;
            let pending = self.state().pending_keys();
            self.write_subscribes(pending).await;
        }
    }

    /// Sends one subscribe per identifier. The caller holds the write lock from before the
    /// identifiers were listed until this returns, so nothing else can get a command out in
    /// between. Otherwise an unsubscribe that lands mid-list could be written ahead of the
    /// subscribe for the same identifier, and the server would end up holding a
    /// subscription nobody here knows about — one it would silently ignore every later
    /// subscribe for.
    async fn write_subscribes(&self, keys: Vec<String>) {
        for key in keys {
            if let Err(error) = self.write(Command::subscribe(&key)).await {
                tracing::debug!(%key, %error, "resubscribing; the next welcome will send it again");
            }
        }
    }

    /// Asks the server for one identifier. Failing is fine: the next welcome asks again.
    async fn send_subscribe(&self, key: &str) {
        if let Err(error) = self.send(Command::subscribe(key)).await {
            tracing::debug!(%key, %error, "subscribing; the next welcome will send it again");
        }
    }

    /// Only an identifier still waiting has news. The server can confirm twice when a
    /// retried subscribe crosses the first confirmation.
    fn confirm(&self, key: &str) {
        let (holders, reconnected) = {
            let mut state = self.state();
            let reconnected = state.reconnected;
            match state.channels.get_mut(key) {
                Some(channel) if !channel.confirmed => {
                    channel.confirmed = true;
                    (channel.holders.clone(), reconnected)
                }
                _ => (Vec::new(), reconnected),
            }
        };

        for holder in holders {
            holder.confirm(reconnected);
        }
    }

    fn reject(&self, key: &str) {
        let holders = self
            .state()
            .channels
            .remove(key)
            .map(|channel| channel.holders)
            .unwrap_or_default();

        for holder in holders {
            holder.reject();
        }
    }

    fn deliver(&self, incoming: Incoming) {
        let holders = self.state().holders(&incoming.identifier);

        match incoming.message {
            Some(message) if holders.is_empty() => {
                tracing::debug!(identifier = %incoming.identifier, %message, "no subscription, dropping message");
            }
            Some(message) => {
                for holder in holders {
                    if !holder.deliver(message.clone()) {
                        tracing::warn!(identifier = %incoming.identifier, "message buffer full, dropping message");
                    }
                }
            }
            None => {
                tracing::debug!(identifier = %incoming.identifier, "frame without a message, dropping it");
            }
        }
    }

    fn hang_up(&self, incoming: Incoming) -> Error {
        let disconnect = Error::Disconnected {
            reason: incoming.reason,
            reconnect: incoming.reconnect,
        };
        if incoming.reconnect {
            disconnect
        } else {
            self.stop(disconnect)
        }
    }

    /// Tears down the current connection, if there is one, and tells every subscription.
    async fn disconnect(&self) {
        let conn = {
            let mut state = self.state();
            state.protocol = None;
            state.welcomed = false;
            state.unconfirm_channels();
            state.conn.take()
        };

        if let Some(conn) = conn {
            conn.close().await;
            self.announce_disconnected();
        }
    }

    /// Tells every subscription the connection is gone and whether the client is coming
    /// back.
    fn announce_disconnected(&self) {
        let (registrations, will_reconnect) = {
            let mut state = self.state();
            let will_reconnect = !state.stopped;
            if !will_reconnect {
                state.stop_announced = true;
            }
            (state.registrations(), will_reconnect)
        };

        for registration in registrations {
            registration.disconnect(will_reconnect);
        }
    }

    fn count_attempt(&self, error: &Error) -> u32 {
        let mut state = self.state();
        state.attempts += 1;
        state.last_error = Some(error.clone());
        state.attempts
    }

    /// Doubles the delay per failed attempt, up to the longest, and spreads the result over
    /// the last interval so a restarted server doesn't get every client back at the same
    /// instant.
    fn reconnect_delay(&self) -> Duration {
        let attempts = self.state().attempts;
        let doublings = attempts.saturating_sub(1).min(16);
        let delay = self
            .config
            .initial_backoff
            .saturating_mul(1 << doublings)
            .min(self.config.longest_backoff);
        let half = delay / 2;
        half + jitter(half)
    }

    /// A client closed while waiting to redial has no connection to tear down, but its
    /// subscriptions still need to hear it isn't coming back, unless the last connection's
    /// end already told them.
    fn announce_stop(&self) {
        if !self.state().stop_announced {
            self.announce_disconnected();
        }
    }

    fn close_subscriptions(&self) {
        let (registrations, failure) = {
            let mut state = self.state();
            let registrations = state.registrations();
            state.channels.clear();
            (registrations, state.failure_or_closed())
        };

        for registration in registrations {
            registration.close(&failure);
        }
    }

    /// Shuts the client down for good: some failures don't get better by dialing again.
    fn stop(&self, error: Error) -> Error {
        {
            let mut state = self.state();
            state.stopped = true;
            state.failure.get_or_insert(error.clone());
        }
        self.stopping.send_replace(true);
        error
    }

    fn is_stopped(&self) -> bool {
        self.state().stopped
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A random duration between zero and `up_to`, inclusive. An `up_to` beyond `u64::MAX`
/// nanoseconds, about 584 years, is treated as that, and an operating system that won't
/// hand over random bytes gets no jitter rather than a panic: the delay itself still holds.
fn jitter(up_to: Duration) -> Duration {
    let nanos = u64::try_from(up_to.as_nanos()).unwrap_or(u64::MAX);
    let random = getrandom::u64().unwrap_or(0);
    Duration::from_nanos(random % nanos.saturating_add(1))
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use super::*;

    #[test]
    fn jitter_stays_within_the_interval() {
        for _ in 0..100 {
            assert!(jitter(Duration::from_millis(10)) <= Duration::from_millis(10));
        }
        assert_eq!(Duration::ZERO, jitter(Duration::ZERO));
        assert!(jitter(Duration::MAX) <= Duration::from_nanos(u64::MAX));
    }
}
