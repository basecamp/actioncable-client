//! Subscriptions: what arrives on them, what goes out from them, what happens to them when
//! the connection comes and goes, and when the callbacks and the event stream run.

#![cfg(feature = "test-support")]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]

mod support;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use actioncable::test_support::{FakeTransport, quote};
use actioncable::{Error, Event, Identifier, SubscribeRequest};
use serde_json::json;
use support::{
    ROOM, Said, builder, next_event, quick_backoff, receive, room, subscribe, subscribed, welcomed,
    within,
};
use tokio::sync::Notify;
use tokio::sync::mpsc::unbounded_channel;

#[tokio::test]
async fn subscribe_receives_messages() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let subscribing = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let subscription = within(subscribing).await.unwrap().unwrap();
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await,
        "the first connection reported itself as a reconnect"
    );

    conn.broadcast(ROOM, r#"{"body":"Hello!"}"#).await;

    let said: Said = receive(&subscription).await.decode().unwrap();
    assert_eq!("Hello!", said.body);
    assert_eq!(ROOM, subscription.key());
    assert!(subscription.err().is_none(), "a live subscription");
}

#[tokio::test]
async fn subscribe_rejected() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let subscribing = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.reject(ROOM).await;

    assert!(matches!(
        within(subscribing).await.unwrap(),
        Err(Error::Rejected { key }) if key == ROOM
    ));
}

#[tokio::test]
async fn subscribe_before_connect() {
    let client = builder(&FakeTransport::new()).build().unwrap();

    assert!(matches!(
        client.subscribe(room()).await,
        Err(Error::NotConnected)
    ));
}

#[tokio::test]
async fn a_rejection_after_a_reconnect_reports_why() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );

    conn.close();
    assert_eq!(
        Event::Disconnected {
            will_reconnect: true
        },
        next_event(&subscription).await
    );

    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
    reconnected.reject(ROOM).await;

    assert_eq!(Event::Rejected, next_event(&subscription).await);
    assert_eq!(None, within(subscription.next_event()).await);
    assert_eq!(None, within(subscription.next()).await);
    assert!(matches!(
        subscription.err(),
        Some(Error::Rejected { key }) if key == ROOM
    ));
}

#[tokio::test]
async fn perform_sends_an_action() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    subscription
        .perform("speak", json!({ "body": "Hello!" }))
        .await
        .unwrap();

    let command = conn.expect_command("message", ROOM).await;
    assert_eq!(
        Some(r#"{"action":"speak","body":"Hello!"}"#.to_string()),
        command.data,
        "expected the action alongside the data"
    );
}

#[tokio::test]
async fn send_delivers_data_without_an_action() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    subscription
        .send(json!({ "body": "Hello!" }))
        .await
        .unwrap();

    let command = conn.expect_command("message", ROOM).await;
    assert_eq!(
        Some(r#"{"body":"Hello!"}"#.to_string()),
        command.data,
        "expected the data on its own"
    );
}

#[tokio::test]
async fn send_refuses_data_that_cannot_encode() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    let unencodable = BTreeMap::from([(vec![1_u8], "no string keys")]);

    assert!(matches!(
        subscription.send(&unencodable).await,
        Err(Error::Json(_))
    ));
    conn.expect_silence().await;
}

#[tokio::test]
async fn perform_refuses_data_that_is_not_an_object() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    assert!(matches!(
        subscription.perform("speak", vec!["nope"]).await,
        Err(Error::DataNotAnObject { action }) if action == "speak"
    ));
    conn.expect_silence().await;
}

#[tokio::test]
async fn perform_before_the_welcome_is_refused() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    conn.close();
    transport.accept().await;

    // The connection is up again but not yet welcomed, and the server throws away anything
    // sent that early, so a command then is not a command landed.
    assert!(matches!(
        subscription.perform("speak", ()).await,
        Err(Error::NotConnected)
    ));
}

#[tokio::test]
async fn unsubscribe_closes_messages_and_tells_the_server() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    subscription.unsubscribe().await.unwrap();

    conn.expect_command("unsubscribe", ROOM).await;
    assert_eq!(None, within(subscription.next()).await);
}

#[tokio::test]
async fn an_unsubscribed_subscription_reports_why() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    assert!(
        subscription.err().is_none(),
        "a live subscription has nothing to report"
    );

    subscription.unsubscribe().await.unwrap();
    conn.expect_command("unsubscribe", ROOM).await;

    assert!(matches!(subscription.err(), Some(Error::Unsubscribed)));
}

/// The Go client's `Unsubscribe` takes no context, so a teardown whose context has already
/// ended can still hang up. Here there is nothing to take: the command goes out on the
/// client's own connection however the subscriber got hold of the subscription.
#[tokio::test]
async fn unsubscribe_outlives_the_wait_that_made_the_subscription() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let subscribing = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let subscription = within(subscribing).await.unwrap().unwrap();

    subscription.unsubscribe().await.unwrap();

    conn.expect_command("unsubscribe", ROOM).await;
}

#[tokio::test]
async fn reconnect_resubscribes() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );

    conn.close();

    assert_eq!(
        Event::Disconnected {
            will_reconnect: true
        },
        next_event(&subscription).await
    );
    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
    reconnected.confirm(ROOM).await;
    assert_eq!(
        Event::Connected { reconnected: true },
        next_event(&subscription).await,
        "the confirmation after a reconnect should report a reconnect"
    );
}

#[tokio::test]
async fn an_unconfirmed_subscribe_is_retried() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .subscribe_retry(Duration::from_millis(20))
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;

    let subscribing = subscribe(&client, room());
    // The first one falls on the floor, the way the server drops a subscribe that reaches
    // it before the connection is set up, so the guarantor sends it again.
    conn.expect_command("subscribe", ROOM).await;
    conn.expect_command("subscribe", ROOM).await;

    conn.confirm(ROOM).await;
    within(subscribing).await.unwrap().unwrap();
}

#[tokio::test]
async fn close_closes_subscriptions() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    client.close().await;

    assert_eq!(None, within(subscription.next()).await);
    assert!(matches!(subscription.err(), Some(Error::Closed)));
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );
    assert_eq!(
        Event::Disconnected {
            will_reconnect: false
        },
        next_event(&subscription).await
    );
    assert_eq!(None, within(subscription.next_event()).await);
    assert!(matches!(
        subscription.perform("speak", ()).await,
        Err(Error::NotConnected)
    ));
    assert!(!client.connected());
}

#[tokio::test]
async fn messages_arrive_on_every_subscription_sharing_an_identifier() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let first = subscribed(&client, &conn).await;
    let second = within(client.subscribe(room())).await.unwrap();

    conn.broadcast(ROOM, r#"{"body":"Hello!"}"#).await;

    for subscription in [&first, &second] {
        assert_eq!(r#"{"body":"Hello!"}"#, receive(subscription).await.as_str());
    }

    // Only the last subscription standing tells the server to unsubscribe.
    first.unsubscribe().await.unwrap();
    conn.expect_silence().await;

    second.unsubscribe().await.unwrap();
    conn.expect_command("unsubscribe", ROOM).await;
}

#[tokio::test]
async fn a_second_subscribe_to_a_confirmed_identifier_asks_the_server_nothing() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let first = subscribed(&client, &conn).await;

    // Rails has the identifier already and would ignore a second subscribe, so the one
    // confirmation it gave stands for this subscription too.
    let second = within(client.subscribe(room())).await.unwrap();

    conn.expect_silence().await;
    for subscription in [&first, &second] {
        assert_eq!(
            Event::Connected { reconnected: false },
            next_event(subscription).await,
            "a subscription joining a confirmed identifier reported itself as a reconnect"
        );
    }

    conn.close();
    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
    reconnected.expect_silence().await;
    reconnected.confirm(ROOM).await;
    for subscription in [&first, &second] {
        assert_eq!(
            Event::Disconnected {
                will_reconnect: true
            },
            next_event(subscription).await
        );
        assert_eq!(
            Event::Connected { reconnected: true },
            next_event(subscription).await
        );
    }

    let third = within(client.subscribe(room())).await.unwrap();
    reconnected.expect_silence().await;
    assert_eq!(
        Event::Connected { reconnected: true },
        next_event(&third).await
    );
}

#[tokio::test]
async fn handles_joining_a_pending_subscribe_share_its_confirmation() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let first = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    let second = subscribe(&client, room());
    let third = subscribe(&client, room());
    conn.expect_silence().await;

    conn.confirm(ROOM).await;

    let first = within(first).await.unwrap().unwrap();
    let second = within(second).await.unwrap().unwrap();
    let third = within(third).await.unwrap().unwrap();
    for subscription in [&first, &second, &third] {
        assert_eq!(
            Event::Connected { reconnected: false },
            next_event(subscription).await
        );
    }
    conn.expect_silence().await;
}

#[tokio::test]
async fn handles_joining_a_pending_subscribe_share_its_rejection() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let first = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    let second = subscribe(&client, room());
    conn.expect_silence().await;

    conn.reject(ROOM).await;

    for subscribing in [first, second] {
        assert!(matches!(
            within(subscribing).await.unwrap(),
            Err(Error::Rejected { key }) if key == ROOM
        ));
    }
    conn.expect_silence().await;

    let again = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    within(again).await.unwrap().unwrap();
}

#[tokio::test]
async fn handles_joining_a_pending_subscribe_follow_it_through_a_reconnect() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let first = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    let second = subscribe(&client, room());
    conn.expect_silence().await;

    conn.close();

    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
    reconnected.expect_silence().await;
    reconnected.confirm(ROOM).await;

    within(first).await.unwrap().unwrap();
    within(second).await.unwrap().unwrap();
}

/// The server has the subscription whether or not anyone here still wants it, and would
/// ignore the next subscribe for it unless told to let go.
#[tokio::test]
async fn a_subscribe_given_up_on_is_forgotten_and_taken_back() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let given_up = tokio::time::timeout(Duration::from_millis(50), client.subscribe(room())).await;
    assert!(
        given_up.is_err(),
        "the subscribe returned without a confirmation"
    );
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    conn.expect_command("unsubscribe", ROOM).await;

    conn.broadcast(ROOM, r#"{"body":"late"}"#).await;

    let subscription = subscribed(&client, &conn).await;
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(100), subscription.next())
            .await
            .is_err(),
        "the late message reached the new subscription"
    );
}

#[tokio::test]
async fn a_joiner_given_up_on_leaves_the_first_subscribe_alone() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    let first = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    let given_up = tokio::time::timeout(Duration::from_millis(50), client.subscribe(room())).await;
    assert!(given_up.is_err(), "the joiner returned without a verdict");
    conn.expect_silence().await;

    conn.confirm(ROOM).await;

    let first = within(first).await.unwrap().unwrap();
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&first).await
    );
}

#[tokio::test]
async fn unsubscribe_while_messages_arrive() {
    let transport = FakeTransport::new();
    let client = builder(&transport).message_buffer(1).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    for _ in 0..50 {
        let subscription = subscribed(&client, &conn).await;

        let pushing = tokio::spawn({
            let conn = Arc::clone(&conn);
            async move { conn.broadcast(ROOM, r#"{"body":"Hello!"}"#).await }
        });

        subscription.unsubscribe().await.unwrap();
        within(pushing).await.unwrap();
        conn.expect_command("unsubscribe", ROOM).await;
    }
}

#[tokio::test]
async fn messages_beyond_the_buffer_are_dropped() {
    let transport = FakeTransport::new();
    let client = builder(&transport).message_buffer(1).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    for body in ["first", "second", "third"] {
        conn.broadcast(ROOM, &format!(r#"{{"body":"{body}"}}"#))
            .await;
    }
    conn.push(r#"{"type":"ping","message":1755400000}"#).await;

    assert_eq!(r#"{"body":"first"}"#, receive(&subscription).await.as_str());
    assert!(
        tokio::time::timeout(Duration::from_millis(100), subscription.next())
            .await
            .is_err(),
        "expected the overflow to be dropped"
    );

    conn.broadcast(ROOM, r#"{"body":"fourth"}"#).await;
    assert_eq!(
        r#"{"body":"fourth"}"#,
        receive(&subscription).await.as_str()
    );
}

#[tokio::test]
async fn dropping_the_last_handle_unsubscribes() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;
    let handle = subscription.clone();

    drop(subscription);
    conn.expect_silence().await;
    conn.broadcast(ROOM, r#"{"body":"still here"}"#).await;
    assert_eq!(r#"{"body":"still here"}"#, receive(&handle).await.as_str());

    drop(handle);
    conn.expect_command("unsubscribe", ROOM).await;
    conn.broadcast(ROOM, r#"{"body":"nobody home"}"#).await;
    conn.expect_silence().await;

    let again = subscribe(&client, room());
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    within(again).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_repeated_confirmation_connects_once() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );

    conn.confirm(ROOM).await;

    assert!(
        tokio::time::timeout(Duration::from_millis(100), subscription.next_event())
            .await
            .is_err(),
        "a second confirmation reported a second connection"
    );
}

#[tokio::test]
async fn a_handle_that_never_reads_events_keeps_only_the_latest() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let mut conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    for _ in 0..20 {
        conn.close();
        conn = transport.accept().await;
        conn.welcome().await;
        conn.expect_command("subscribe", ROOM).await;
        conn.confirm(ROOM).await;
        conn.broadcast(ROOM, r#"{"body":"settled"}"#).await;
        assert_eq!(
            r#"{"body":"settled"}"#,
            receive(&subscription).await.as_str()
        );
    }

    let mut kept = Vec::new();
    while let Ok(Some(event)) =
        tokio::time::timeout(Duration::from_millis(100), subscription.next_event()).await
    {
        kept.push(event);
    }

    let mut latest = Vec::new();
    for _ in 0..8 {
        latest.push(Event::Disconnected {
            will_reconnect: true,
        });
        latest.push(Event::Connected { reconnected: true });
    }
    assert_eq!(latest, kept);
}

#[tokio::test]
async fn callbacks_follow_the_connection() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let (record, mut recorded) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room())
            .on_connected({
                let record = record.clone();
                move |reconnected| {
                    let record = record.clone();
                    async move { record.send(format!("connected {reconnected}")).unwrap() }
                }
            })
            .on_disconnected({
                let record = record.clone();
                move |will_reconnect| {
                    let record = record.clone();
                    async move {
                        record
                            .send(format!("disconnected {will_reconnect}"))
                            .unwrap();
                    }
                }
            })
            .on_rejected(move || {
                let record = record.clone();
                async move { record.send("rejected".to_string()).unwrap() }
            });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let subscription = within(subscribing).await.unwrap().unwrap();
    assert_eq!("connected false", within(recorded.recv()).await.unwrap());

    conn.close();
    assert_eq!("disconnected true", within(recorded.recv()).await.unwrap());
    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
    reconnected.confirm(ROOM).await;
    assert_eq!("connected true", within(recorded.recv()).await.unwrap());

    reconnected.close();
    assert_eq!("disconnected true", within(recorded.recv()).await.unwrap());
    let again = transport.accept().await;
    again.welcome().await;
    again.expect_command("subscribe", ROOM).await;
    again.reject(ROOM).await;
    assert_eq!("rejected", within(recorded.recv()).await.unwrap());
    assert_eq!(None, within(recorded.recv()).await);
    assert_eq!(None, within(subscription.next()).await);
}

#[tokio::test]
async fn a_disconnect_for_good_says_so_to_the_callback() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let (record, mut recorded) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room()).on_disconnected(move |will_reconnect| {
            let record = record.clone();
            async move { record.send(will_reconnect).unwrap() }
        });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let _subscription = within(subscribing).await.unwrap().unwrap();

    client.close().await;

    assert_eq!(Some(false), within(recorded.recv()).await);
    assert_eq!(None, within(recorded.recv()).await);
}

#[tokio::test]
async fn a_rejected_first_subscribe_reaches_the_callback() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let (record, mut recorded) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room()).on_rejected(move || {
            let record = record.clone();
            async move { record.send("rejected").unwrap() }
        });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.reject(ROOM).await;

    assert!(matches!(
        within(subscribing).await.unwrap(),
        Err(Error::Rejected { .. })
    ));
    assert_eq!(Some("rejected"), within(recorded.recv()).await);
}

#[tokio::test]
async fn close_and_subscribe_work_from_inside_a_callback() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let other = r#"{"channel":"OtherChannel"}"#;
    let (finished, mut finishing) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room())
            .on_connected({
                let client = client.clone();
                let finished = finished.clone();
                move |_| {
                    let client = client.clone();
                    let finished = finished.clone();
                    async move {
                        let other = client.subscribe(Identifier::new("OtherChannel")).await;
                        finished.send(other.map(|_| "subscribed")).unwrap();
                    }
                }
            })
            .on_disconnected({
                let client = client.clone();
                move |_| {
                    let client = client.clone();
                    let finished = finished.clone();
                    async move {
                        client.close().await;
                        finished.send(Ok("closed")).unwrap();
                    }
                }
            });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let _subscription = within(subscribing).await.unwrap().unwrap();
    conn.expect_command("subscribe", other).await;
    conn.confirm(other).await;
    assert_eq!(
        "subscribed",
        within(finishing.recv()).await.unwrap().unwrap()
    );

    conn.close();

    assert_eq!("closed", within(finishing.recv()).await.unwrap().unwrap());
    assert!(matches!(client.connect().await, Err(Error::Closed)));
}

/// A reader that sees the message stream end knows no callback is still running or about
/// to: the stream ends behind the last of them.
#[tokio::test]
async fn messages_close_after_the_last_callback_returns() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let entered = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room()).on_disconnected({
            let entered = Arc::clone(&entered);
            let release = Arc::clone(&release);
            move |_| {
                let entered = Arc::clone(&entered);
                let release = Arc::clone(&release);
                async move {
                    entered.notify_one();
                    release.notified().await;
                }
            }
        });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let subscription = within(subscribing).await.unwrap().unwrap();

    client.close().await;
    within(entered.notified()).await;

    assert!(
        tokio::time::timeout(Duration::from_millis(100), subscription.next())
            .await
            .is_err(),
        "the message stream ended while a callback was still running"
    );

    release.notify_one();

    assert_eq!(None, within(subscription.next()).await);
    assert!(matches!(subscription.err(), Some(Error::Closed)));
}

#[tokio::test]
async fn close_from_a_disconnect_callback() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let (closed, mut closing) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room()).on_disconnected({
            let client = client.clone();
            move |_| {
                let client = client.clone();
                let closed = closed.clone();
                async move {
                    client.close().await;
                    closed.send(()).unwrap();
                }
            }
        });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let _subscription = within(subscribing).await.unwrap().unwrap();

    conn.close();

    assert_eq!(Some(()), within(closing.recv()).await);
    assert!(matches!(client.connect().await, Err(Error::Closed)));
}

#[tokio::test]
async fn subscribe_from_a_connected_callback() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let other = r#"{"channel":"OtherChannel"}"#;
    let (subscribed_other, mut subscribing_other) = unbounded_channel();

    let subscribing = tokio::spawn({
        let client = client.clone();
        let request = SubscribeRequest::new(room()).on_connected({
            let client = client.clone();
            move |_| {
                let client = client.clone();
                let subscribed_other = subscribed_other.clone();
                async move {
                    let other = client.subscribe(Identifier::new("OtherChannel")).await;
                    subscribed_other.send(other.is_ok()).unwrap();
                }
            }
        });
        async move { client.subscribe(request).await }
    });
    conn.expect_command("subscribe", ROOM).await;
    conn.confirm(ROOM).await;
    let _subscription = within(subscribing).await.unwrap().unwrap();

    conn.expect_command("subscribe", other).await;
    conn.confirm(other).await;

    assert_eq!(Some(true), within(subscribing_other.recv()).await);
}

#[tokio::test]
async fn a_message_without_a_payload_is_dropped() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    conn.push(&format!(r#"{{"identifier":{}}}"#, quote(ROOM)))
        .await;
    conn.broadcast(ROOM, r#"{"body":"the next one"}"#).await;

    assert_eq!(
        r#"{"body":"the next one"}"#,
        receive(&subscription).await.as_str(),
        "the empty frame was delivered rather than dropped"
    );
}
