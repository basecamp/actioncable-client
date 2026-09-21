use std::fmt;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use serde::Serialize;
use serde_json::{Map, Value};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, oneshot, watch};

use crate::client;
use crate::error::Error;
use crate::identifier::Identifier;
use crate::message::Message;
use crate::protocol::Command;

/// How many connection events a subscription keeps for a handle that isn't reading them.
/// One connection makes two, so this covers eight reconnects nobody looked at.
const EVENT_BUFFER: usize = 16;

/// What happened to a subscription's connection. Some channels only send what's new, so a
/// reconnect can leave a gap, and only the client knows a reconnect happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The server confirmed the subscription. `reconnected` is false the first time and true
    /// every time after, which is when a channel that only streams what's new has a gap to
    /// fill.
    Connected {
        /// False the first time, true every time after.
        reconnected: bool,
    },
    /// The connection dropped. `will_reconnect` says whether the client is coming back or
    /// has stopped for good.
    Disconnected {
        /// Whether the client is coming back or has stopped for good.
        will_reconnect: bool,
    },
    /// The channel rejected the subscription. On the first subscribe that is also the
    /// [`Error::Rejected`] the call returns, so a handle only ever reads this after a
    /// reconnect. Nothing more arrives; the client has already let go of it.
    Rejected,
}

/// One channel subscription on a client. Read what the channel sends with
/// [`next`](Subscription::next), watch the connection with
/// [`next_event`](Subscription::next_event), and talk back with
/// [`perform`](Subscription::perform) or [`send`](Subscription::send).
///
/// Handles are cheap to clone and share one stream of messages: a message goes to whichever
/// handle reads it first. The subscription outlives reconnects, resubscribed automatically,
/// until [`unsubscribe`](Subscription::unsubscribe). Dropping the last handle unsubscribes
/// too, when it happens on a tokio runtime; elsewhere it stops delivery and warns, and the
/// server keeps the subscription until the connection ends.
#[derive(Clone)]
pub struct Subscription {
    inner: Arc<Inner>,
}

struct Inner {
    client: Weak<client::Inner>,
    registration: Arc<Registration>,
    messages: tokio::sync::Mutex<mpsc::Receiver<Message>>,
    events: tokio::sync::Mutex<broadcast::Receiver<Event>>,
    /// Flips when the callback task has run its last callback, so the message stream can
    /// end behind it rather than in front of it.
    callbacks: Option<Arc<watch::Sender<bool>>>,
}

impl Subscription {
    pub(crate) fn new(
        client: Weak<client::Inner>,
        registration: Arc<Registration>,
        receivers: Receivers,
        callbacks: Option<Arc<watch::Sender<bool>>>,
    ) -> Subscription {
        Subscription {
            inner: Arc::new(Inner {
                client,
                registration,
                messages: tokio::sync::Mutex::new(receivers.messages),
                events: tokio::sync::Mutex::new(receivers.events),
                callbacks,
            }),
        }
    }

    /// The JSON identifier the server knows this subscription by, and echoes back on
    /// everything it sends here.
    pub fn key(&self) -> &str {
        &self.inner.registration.key
    }

    /// The next message the channel broadcast or transmitted, or `None` once the
    /// subscription is unsubscribed, rejected, or the client is closed —
    /// [`err`](Subscription::err) says which. The last callback has returned by then, so a
    /// loop that ends knows none is still running or about to.
    ///
    /// Read it promptly. A message that arrives with the buffer full is dropped and logged
    /// rather than stalling the connection; [`ClientBuilder::message_buffer`] sizes the
    /// buffer for a slow reader.
    ///
    /// [`ClientBuilder::message_buffer`]: crate::ClientBuilder::message_buffer
    pub async fn next(&self) -> Option<Message> {
        let message = self.inner.messages.lock().await.recv().await;

        if message.is_none()
            && let Some(callbacks) = &self.inner.callbacks
        {
            let mut finished = callbacks.subscribe();
            let _last = finished.wait_for(|finished| *finished).await;
        }
        message
    }

    /// Why the subscription ended: [`Error::Unsubscribed`], [`Error::Rejected`], or
    /// whatever stopped the client. `None` while it is live.
    pub fn err(&self) -> Option<Error> {
        self.inner.registration.reason()
    }

    /// The next connection event, in the order they happened, or `None` once the
    /// subscription is over.
    ///
    /// A handle keeps the last sixteen events for a reader that isn't listening, and a
    /// reader further behind than that skips the oldest and is told so in the log. Nothing
    /// is lost while events are read as they come, and a handle that never reads them costs
    /// nothing however long the client runs.
    pub async fn next_event(&self) -> Option<Event> {
        let mut events = self.inner.events.lock().await;
        loop {
            match events.recv().await {
                Ok(event) => break Some(event),
                Err(RecvError::Lagged(skipped)) => {
                    tracing::warn!(key = %self.key(), skipped, "connection events went unread and were dropped");
                }
                Err(RecvError::Closed) => break None,
            }
        }
    }

    /// Invokes an action on the channel, the equivalent of the JavaScript client's
    /// `perform`. `data` must encode to a JSON object, the only shape Rails routes to an
    /// action, or to `null`, which sends the action alone; anything else is
    /// [`Error::DataNotAnObject`].
    pub async fn perform(&self, action: &str, data: impl Serialize) -> Result<(), Error> {
        let payload = perform_payload(action, data)?;
        self.client()?
            .send(Command::message(self.key(), payload))
            .await
    }

    /// Delivers `data` to the channel as-is, without naming an action. Rails routes it to
    /// the channel's `receive` method.
    pub async fn send(&self, data: impl Serialize) -> Result<(), Error> {
        let payload = serde_json::to_string(&data)?;
        self.client()?
            .send(Command::message(self.key(), payload))
            .await
    }

    /// Tells the server to drop the subscription and ends both streams. Other subscriptions
    /// to the same identifier keep the server's; it only hears about the unsubscribe from
    /// the last of them.
    pub async fn unsubscribe(&self) -> Result<(), Error> {
        let client = self.client()?;
        if client.forget(&self.inner.registration, &Error::Unsubscribed) {
            client.send(Command::unsubscribe(self.key())).await
        } else {
            Ok(())
        }
    }

    fn client(&self) -> Result<Arc<client::Inner>, Error> {
        self.inner.client.upgrade().ok_or(Error::Closed)
    }
}

impl fmt::Debug for Subscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscription")
            .field("key", &self.key())
            .finish()
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some(client) = self.client.upgrade()
            && client.forget(&self.registration, &Error::Unsubscribed)
        {
            client.unsubscribe_later(&self.registration.key);
        }
    }
}

fn perform_payload(action: &str, data: impl Serialize) -> Result<String, Error> {
    let mut fields = match serde_json::to_value(data)? {
        Value::Object(fields) => Ok(fields),
        Value::Null => Ok(Map::new()),
        _ => Err(Error::DataNotAnObject {
            action: action.to_string(),
        }),
    }?;
    fields.insert("action".to_string(), Value::String(action.to_string()));
    Ok(serde_json::to_string(&fields)?)
}

/// What to subscribe to, and what to do when its connection changes. The callbacks mirror
/// the Go client's `OnConnected`, `OnDisconnected` and `OnRejected`; the same events also
/// arrive on [`Subscription::next_event`], so use whichever reads better. A bare
/// [`Identifier`] converts into a request with no callbacks, which is what
/// [`Client::subscribe`](crate::Client::subscribe) takes most of the time.
///
/// ```no_run
/// use actioncable::{Client, Identifier, SubscribeRequest};
///
/// # async fn run(client: Client) -> Result<(), actioncable::Error> {
/// let room = client
///     .subscribe(
///         SubscribeRequest::new(Identifier::new("RoomChannel"))
///             .on_connected(|reconnected| async move {
///                 if reconnected {
///                     println!("catch up");
///                 }
///             })
///             .on_disconnected(|will_reconnect| async move {
///                 println!("gone, back soon: {will_reconnect}");
///             }),
///     )
///     .await?;
/// # Ok(())
/// # }
/// ```
///
/// Callbacks are async: each returns a future, and `|x| async move { .. }` is how a plain
/// closure becomes one. They run on their own tokio task, one at a time, in the order the
/// events happened, never on the connection's task, and the next event waits for the
/// current callback to finish. [`Client::close`](crate::Client::close),
/// [`Client::subscribe`](crate::Client::subscribe) and
/// [`Subscription::unsubscribe`] can all be awaited from inside one. They live as long as
/// the [`Subscription`] does: dropping the last handle ends the callbacks along with
/// delivery.
pub struct SubscribeRequest {
    identifier: Identifier,
    callbacks: Callbacks,
}

impl SubscribeRequest {
    /// A request for `identifier`, with no callbacks yet.
    pub fn new(identifier: Identifier) -> SubscribeRequest {
        SubscribeRequest {
            identifier,
            callbacks: Callbacks::default(),
        }
    }

    /// Called every time the server confirms the subscription, including after a reconnect,
    /// which is what `reconnected` reports.
    pub fn on_connected<Fut>(
        mut self,
        callback: impl Fn(bool) -> Fut + Send + Sync + 'static,
    ) -> SubscribeRequest
    where
        Fut: Future<Output = ()> + Send + 'static,
    {
        self.callbacks.connected =
            Some(Box::new(move |reconnected| Box::pin(callback(reconnected))));
        self
    }

    /// Called when the connection drops, with whether the client intends to dial again.
    pub fn on_disconnected<Fut>(
        mut self,
        callback: impl Fn(bool) -> Fut + Send + Sync + 'static,
    ) -> SubscribeRequest
    where
        Fut: Future<Output = ()> + Send + 'static,
    {
        self.callbacks.disconnected = Some(Box::new(move |will_reconnect| {
            Box::pin(callback(will_reconnect))
        }));
        self
    }

    /// Called when the channel rejects the subscription.
    pub fn on_rejected<Fut>(
        mut self,
        callback: impl Fn() -> Fut + Send + Sync + 'static,
    ) -> SubscribeRequest
    where
        Fut: Future<Output = ()> + Send + 'static,
    {
        self.callbacks.rejected = Some(Box::new(move |()| Box::pin(callback())));
        self
    }

    pub(crate) fn into_parts(self) -> (Identifier, Callbacks) {
        (self.identifier, self.callbacks)
    }
}

impl From<Identifier> for SubscribeRequest {
    fn from(identifier: Identifier) -> SubscribeRequest {
        SubscribeRequest::new(identifier)
    }
}

type Callback<Arg> = Box<dyn Fn(Arg) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

#[derive(Default)]
pub(crate) struct Callbacks {
    connected: Option<Callback<bool>>,
    disconnected: Option<Callback<bool>>,
    rejected: Option<Callback<()>>,
}

impl Callbacks {
    fn is_empty(&self) -> bool {
        self.connected.is_none() && self.disconnected.is_none() && self.rejected.is_none()
    }

    /// Starts the task that runs the callbacks, and hands back what flips when it has run
    /// its last one. Nothing to call means no task and nothing to wait for.
    pub(crate) fn spawn(
        self,
        events: broadcast::Receiver<Event>,
    ) -> Option<Arc<watch::Sender<bool>>> {
        if self.is_empty() {
            return None;
        }

        let finished = Arc::new(watch::Sender::new(false));
        let last = Arc::clone(&finished);
        tokio::spawn(async move {
            self.run(events).await;
            last.send_replace(true);
        });

        Some(finished)
    }

    /// Runs the callbacks for every event as it arrives, one at a time, and ends with the
    /// stream.
    async fn run(self, mut events: broadcast::Receiver<Event>) {
        loop {
            match events.recv().await {
                Ok(Event::Connected { reconnected }) => {
                    if let Some(callback) = &self.connected {
                        callback(reconnected).await;
                    }
                }
                Ok(Event::Disconnected { will_reconnect }) => {
                    if let Some(callback) = &self.disconnected {
                        callback(will_reconnect).await;
                    }
                }
                Ok(Event::Rejected) => {
                    if let Some(callback) = &self.rejected {
                        callback(()).await;
                    }
                }
                Err(RecvError::Lagged(skipped)) => {
                    tracing::warn!(
                        skipped,
                        "a callback fell behind and missed connection events"
                    );
                }
                Err(RecvError::Closed) => break,
            }
        }
    }
}

/// The server's verdict on a subscribe command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Decision {
    Confirmed,
    Rejected,
}

/// The client's side of one handle: what it needs to route frames to the handle and to
/// tell it how the subscription is doing. Whether the server has confirmed the identifier
/// is the client's to know, since every handle on one identifier shares that answer.
pub(crate) struct Registration {
    pub(crate) key: String,
    decision: Mutex<Option<oneshot::Sender<Decision>>>,
    messages: Mutex<Option<mpsc::Sender<Message>>>,
    /// Every listener gets every event; none steals from another. Taken on close, so
    /// nothing is announced to a subscription that is over.
    events: Mutex<Option<broadcast::Sender<Event>>>,
    /// Why the subscription ended, set once by whoever ended it.
    reason: Mutex<Option<Error>>,
}

/// The handle's ends of a registration's channels.
pub(crate) struct Receivers {
    pub(crate) decision: oneshot::Receiver<Decision>,
    pub(crate) messages: mpsc::Receiver<Message>,
    pub(crate) events: broadcast::Receiver<Event>,
}

impl Registration {
    pub(crate) fn register(key: String, buffer: usize) -> (Arc<Registration>, Receivers) {
        let (decide, decision) = oneshot::channel();
        let (deliver, messages) = mpsc::channel(buffer.max(1));
        let (announce, events) = broadcast::channel(EVENT_BUFFER);
        let registration = Arc::new(Registration {
            key,
            decision: Mutex::new(Some(decide)),
            messages: Mutex::new(Some(deliver)),
            events: Mutex::new(Some(announce)),
            reason: Mutex::new(None),
        });
        (
            registration,
            Receivers {
                decision,
                messages,
                events,
            },
        )
    }

    /// A second stream of the same events, for the callbacks. One asked for after the
    /// registration closed is over before it starts.
    pub(crate) fn watch_events(&self) -> broadcast::Receiver<Event> {
        match self
            .events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            Some(announce) => announce.subscribe(),
            None => broadcast::channel(1).1,
        }
    }

    /// Passes the server's verdict on. The event goes out before the verdict: whoever is
    /// waiting on the subscribe may unsubscribe the moment it wakes, and that must not get
    /// ahead of the callback for the event that woke it.
    pub(crate) fn confirm(&self, reconnected: bool) {
        self.announce(Event::Connected { reconnected });
        self.decide(Decision::Confirmed);
    }

    pub(crate) fn reject(&self) {
        self.announce(Event::Rejected);
        self.decide(Decision::Rejected);
        self.close(&Error::Rejected {
            key: self.key.clone(),
        });
    }

    pub(crate) fn disconnect(&self, will_reconnect: bool) {
        self.announce(Event::Disconnected { will_reconnect });
    }

    /// Hands a message to the reader, and reports whether there was room. A closed
    /// subscription has nothing left to receive, and nothing to report.
    pub(crate) fn deliver(&self, message: Message) -> bool {
        match self
            .messages
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            Some(deliver) => deliver.try_send(message).is_ok(),
            None => true,
        }
    }

    /// Ends both streams for the reason given, which the first one to end it wins. The
    /// reader drains what was buffered and then sees `None`.
    pub(crate) fn close(&self, reason: &Error) {
        self.reason
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_or_insert_with(|| reason.clone());
        self.messages
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        self.events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
    }

    /// Why the subscription ended, `None` while it is live.
    fn reason(&self) -> Option<Error> {
        self.reason
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn decide(&self, decision: Decision) {
        if let Some(decide) = self
            .decision
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
            && decide.send(decision).is_err()
        {
            tracing::trace!(key = %self.key, "nobody is waiting on the subscribe");
        }
    }

    fn announce(&self, event: Event) {
        if let Some(announce) = self
            .events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            && announce.send(event).is_err()
        {
            tracing::trace!(key = %self.key, "nobody is listening for events");
        }
    }
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]
mod tests {
    use std::collections::BTreeMap;

    use serde_json::json;

    use super::*;

    #[test]
    fn perform_payload_carries_the_action_alongside_the_data() {
        assert_eq!(
            r#"{"action":"speak","body":"Hello!"}"#,
            perform_payload("speak", json!({ "body": "Hello!" })).unwrap()
        );
        assert_eq!(
            r#"{"action":"speak"}"#,
            perform_payload("speak", ()).unwrap()
        );
        assert!(matches!(
            perform_payload("speak", vec!["nope"]),
            Err(Error::DataNotAnObject { action }) if action == "speak"
        ));
        assert!(matches!(
            perform_payload("speak", BTreeMap::from([(vec![1u8], 1u8)])),
            Err(Error::Json(_))
        ));
    }
}
