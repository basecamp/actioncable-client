//! The connection itself: getting one, keeping one, negotiating over one, and what the
//! client does when it can't have one. Driven over the in-memory fake, with the test
//! playing the server.

#![cfg(feature = "test-support")]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test that can't have what it asked for has nothing left to assert"
)]

mod support;

use std::io::ErrorKind;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use actioncable::test_support::{FakeProtocol, FakeTransport, quote};
use actioncable::{
    Client, DisconnectReason, Error, Event, Identifier, Protocol, SUBPROTOCOL_UNSUPPORTED,
    SUBPROTOCOL_V1_JSON, V1Json,
};
use http::{HeaderMap, HeaderValue};
use support::{
    Bearer, ROOM, builder, connect, io_kind, next_event, quick_backoff, receive, room, signed_out,
    stopped, subscribe, subscribed, welcomed, within,
};

#[tokio::test]
async fn connect_waits_for_the_welcome() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();

    let connecting = connect(&client);
    let conn = transport.accept().await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        !connecting.is_finished(),
        "connect returned before the welcome"
    );

    conn.welcome().await;

    within(connecting).await.unwrap().unwrap();
    assert!(client.connected());
}

#[tokio::test]
async fn connect_retries_until_the_server_answers() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport)).build().unwrap();

    let connecting = connect(&client);
    transport.accept().await.welcome().await;

    within(connecting).await.unwrap().unwrap();
}

#[tokio::test]
async fn connect_twice_is_refused() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    welcomed(&client, &transport).await;

    assert!(matches!(
        client.connect().await,
        Err(Error::AlreadyConnected)
    ));
}

#[tokio::test]
async fn connect_after_close_reports_why_it_stopped() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    welcomed(&client, &transport).await;

    client.close().await;

    assert!(matches!(client.connect().await, Err(Error::Closed)));
    transport.refuse_dial().await;
}

#[tokio::test]
async fn close_before_connect_leaves_the_client_dead() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();

    client.close().await;
    client.close().await;

    assert!(matches!(client.connect().await, Err(Error::Closed)));
    assert!(!client.connected());
    transport.refuse_dial().await;
}

#[tokio::test]
async fn a_stale_connection_is_replaced() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .stale_after(Duration::from_millis(75))
        .build()
        .unwrap();

    let connecting = connect(&client);
    transport.accept().await.welcome().await;
    within(connecting).await.unwrap().unwrap();

    // Say nothing at all: no pings, no messages. The connection goes stale.
    transport.accept().await.welcome().await;
    assert!(matches!(client.last_error(), Some(Error::Stale { .. })));
}

#[tokio::test]
async fn a_server_disconnect_without_reconnect_stops_the_client() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.push(r#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)
        .await;

    transport.refuse_dial().await;
    assert!(!client.connected());
    assert!(matches!(
        client.subscribe(room()).await,
        Err(Error::Disconnected {
            reason: Some(DisconnectReason::Unauthorized),
            reconnect: false,
        })
    ));
}

#[tokio::test]
async fn a_server_disconnect_without_a_reason_stops_the_client_all_the_same() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.push(r#"{"type":"disconnect","reconnect":false}"#)
        .await;

    transport.refuse_dial().await;
    assert!(matches!(
        client.subscribe(room()).await,
        Err(Error::Disconnected { reason: None, .. })
    ));
}

#[tokio::test]
async fn a_server_disconnect_with_reconnect_dials_again() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.push(r#"{"type":"disconnect","reason":"server_restart","reconnect":true}"#)
        .await;

    transport.accept().await.welcome().await;
    assert!(client.err().is_none(), "a redial was treated as the end");
}

#[tokio::test]
async fn the_client_offers_every_protocol_and_the_sentinel() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .protocols(vec![Arc::new(V1Json), Arc::new(FakeProtocol::v2())])
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    assert_eq!(
        vec![
            SUBPROTOCOL_V1_JSON,
            "actioncable-v2-json",
            SUBPROTOCOL_UNSUPPORTED
        ],
        transport.dialed_with().subprotocols
    );
}

#[tokio::test]
async fn preferred_protocols_are_offered_first() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .prefer_protocols(vec![Arc::new(FakeProtocol::v2())])
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    assert_eq!(
        vec![
            "actioncable-v2-json",
            SUBPROTOCOL_V1_JSON,
            SUBPROTOCOL_UNSUPPORTED
        ],
        transport.dialed_with().subprotocols
    );
}

#[tokio::test]
async fn the_client_speaks_the_protocol_the_server_picked() {
    let transport = FakeTransport::new();
    transport.speak(Some("actioncable-v2-json"));
    let client = builder(&transport)
        .protocols(vec![Arc::new(V1Json), Arc::new(FakeProtocol::v2())])
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;

    let subscribing = subscribe(&client, room());

    let sent = conn.sent().await;
    assert!(
        sent.starts_with(b"v2:"),
        "expected the negotiated protocol to encode the subscribe, got {}",
        String::from_utf8_lossy(&sent)
    );
    conn.push(&format!(
        r#"v2:{{"type":"confirm_subscription","identifier":{}}}"#,
        quote(ROOM)
    ))
    .await;
    within(subscribing).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_custom_protocol_is_spoken_end_to_end() {
    let transport = FakeTransport::new();
    transport.speak(Some("actioncable-v2-json"));
    let client = builder(&transport)
        .protocols(vec![Arc::new(FakeProtocol::v2()) as Arc<dyn Protocol>])
        .build()
        .unwrap();

    let connecting = connect(&client);
    let conn = transport.accept().await;
    conn.push(r#"v2:{"type":"welcome"}"#).await;
    within(connecting).await.unwrap().unwrap();

    let subscribing = subscribe(&client, room());
    assert_eq!(
        format!(
            r#"v2:{{"command":"subscribe","identifier":{}}}"#,
            quote(ROOM)
        ),
        String::from_utf8(conn.sent().await).unwrap()
    );
    conn.push(&format!(
        r#"v2:{{"type":"confirm_subscription","identifier":{}}}"#,
        quote(ROOM)
    ))
    .await;
    let subscription = within(subscribing).await.unwrap().unwrap();

    conn.push(&format!(
        r#"v2:{{"identifier":{},"message":{{"body":"Hello!"}}}}"#,
        quote(ROOM)
    ))
    .await;
    assert_eq!(
        r#"{"body":"Hello!"}"#,
        receive(&subscription).await.as_str()
    );
}

#[tokio::test]
async fn the_unsupported_sentinel_stops_the_client() {
    let transport = FakeTransport::new();
    transport.speak(Some(SUBPROTOCOL_UNSUPPORTED));
    let client = quick_backoff(builder(&transport)).build().unwrap();

    let error = client.connect().await.unwrap_err();

    assert_eq!(
        "unsupported subprotocol: the server speaks none of actioncable-v1-json",
        error.to_string()
    );
    transport.accept().await;
    transport.refuse_dial().await;
}

#[tokio::test]
async fn an_unknown_subprotocol_stops_the_client() {
    let transport = FakeTransport::new();
    transport.speak(Some("actioncable-v9-telepathy"));
    let client = quick_backoff(builder(&transport)).build().unwrap();

    let error = client.connect().await.unwrap_err();

    assert_eq!(
        "unsupported subprotocol: \"actioncable-v9-telepathy\"",
        error.to_string()
    );
    transport.accept().await;
    transport.refuse_dial().await;
}

#[tokio::test]
async fn no_subprotocol_at_all_stops_the_client() {
    let transport = FakeTransport::new();
    transport.speak(None);
    let client = quick_backoff(builder(&transport)).build().unwrap();

    assert!(matches!(
        client.connect().await,
        Err(Error::UnsupportedSubprotocol { negotiated, .. }) if negotiated.is_empty()
    ));
    transport.accept().await;
    transport.refuse_dial().await;
}

#[tokio::test]
async fn no_protocols_stops_the_client() {
    let transport = FakeTransport::new();
    let client = builder(&transport).protocols(vec![]).build().unwrap();

    assert!(matches!(client.connect().await, Err(Error::NoProtocols)));
    transport.refuse_dial().await;
}

#[tokio::test]
async fn the_origin_defaults_to_the_cable_url() {
    let origins = [
        ("wss://cable.example.com/cable", "https://cable.example.com"),
        (
            "ws://cable.example.com:3000/cable",
            "http://cable.example.com:3000",
        ),
        (
            "wss://cable.example.com:8443/cable",
            "https://cable.example.com:8443",
        ),
    ];

    // Rails compares Origin against the host it serves on, and turns down a request that
    // carries no Origin at all.
    for (url, origin) in origins {
        let transport = FakeTransport::new();
        let client = Client::builder(url)
            .transport(transport.clone())
            .build()
            .unwrap();

        welcomed(&client, &transport).await;

        assert_eq!(
            origin,
            transport.dialed_with().headers.get("origin").unwrap(),
            "{url}"
        );
        client.close().await;
    }
}

#[tokio::test]
async fn an_explicit_origin_wins() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .origin("https://app.example.com")
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    assert_eq!(
        "https://app.example.com",
        transport.dialed_with().headers.get("origin").unwrap()
    );
}

#[tokio::test]
async fn cookies_and_headers_ride_on_the_dial() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .cookie("_session_id=1234")
        .header("X-Api-Token", "secret")
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    let headers = transport.dialed_with().headers;
    assert_eq!("_session_id=1234", headers.get("cookie").unwrap());
    assert_eq!("secret", headers.get("x-api-token").unwrap());
}

/// The Go client neutralizes a header carrying a newline as it writes the request. Here a
/// header is an `http::HeaderValue` from the moment it is given, and one carrying a
/// newline is refused before there is a client to dial with.
#[tokio::test]
async fn header_injection_is_refused() {
    let built = builder(&FakeTransport::new())
        .header("Authorization", "Bearer token\r\nX-Injected: gotcha")
        .build();

    assert!(matches!(
        built,
        Err(Error::InvalidHeader { name, .. }) if name == "Authorization"
    ));
    assert!(matches!(
        builder(&FakeTransport::new())
            .header("not a name", "value")
            .build(),
        Err(Error::InvalidHeader { .. })
    ));
}

#[tokio::test]
async fn every_dial_asks_the_provider_again() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport))
        .origin("https://app.example.com")
        .header_provider(Bearer::new(0))
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    let headers = transport.dialed_with().headers;
    assert_eq!(
        "Bearer token-2",
        headers.get("authorization").unwrap(),
        "expected the redial to carry the credentials it asked for then"
    );
    assert_eq!(
        "https://app.example.com",
        headers.get("origin").unwrap(),
        "expected the headers set once to survive"
    );
}

#[tokio::test]
async fn a_dial_is_turned_down_when_the_headers_cannot_be_built() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .header_provider(Bearer::new(1))
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    assert_eq!(
        "Bearer token-2",
        transport
            .dialed_with()
            .headers
            .get("authorization")
            .unwrap(),
        "expected the client to dial again after the headers failed"
    );
}

#[tokio::test]
async fn a_closure_is_asked_for_headers_on_every_dial() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let asked = Arc::new(AtomicU64::new(0));
    let client = quick_backoff(builder(&transport))
        .header_provider({
            let asked = Arc::clone(&asked);
            move || {
                let asked = Arc::clone(&asked);
                async move {
                    let ask = asked.fetch_add(1, Ordering::SeqCst) + 1;
                    if ask == 2 {
                        Err(Error::headers(std::io::Error::other("token store busy")))
                    } else {
                        let mut headers = HeaderMap::new();
                        headers.insert(
                            "authorization",
                            HeaderValue::from_str(&format!("Bearer token-{ask}")).unwrap(),
                        );
                        Ok(headers)
                    }
                }
            }
        })
        .build()
        .unwrap();

    welcomed(&client, &transport).await;

    assert_eq!(3, asked.load(Ordering::SeqCst));
    assert_eq!(
        "Bearer token-3",
        transport
            .dialed_with()
            .headers
            .get("authorization")
            .unwrap()
    );
}

#[tokio::test]
async fn a_terminal_dial_error_stops_the_initial_connection() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection denied");
    let client = quick_backoff(builder(&transport))
        .stop_on_error(|error| io_kind(error) == Some(ErrorKind::ConnectionRefused))
        .build()
        .unwrap();

    let error = client.connect().await.unwrap_err();

    assert!(error.to_string().contains("connection denied"), "{error}");
    assert!(client.err().is_some(), "the client kept running");
    transport.refuse_dial().await;
}

#[tokio::test]
async fn a_non_terminal_connection_error_still_reconnects() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .stop_on_error(signed_out)
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.close();
    transport.accept().await.welcome().await;

    assert!(
        client.err().is_none(),
        "a retryable error stopped the client"
    );
}

#[tokio::test]
async fn a_terminal_connection_error_stops_subscriptions() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .stop_on_error(|error| io_kind(error) == Some(ErrorKind::UnexpectedEof))
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    conn.close();

    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );
    assert_eq!(
        Event::Disconnected {
            will_reconnect: false
        },
        next_event(&subscription).await,
        "the subscription was promised a reconnect after a terminal error"
    );
    stopped(&client).await;
    assert_eq!(
        Some(ErrorKind::UnexpectedEof),
        io_kind(&client.err().unwrap())
    );
    assert_eq!(None, within(subscription.next()).await);
    assert_eq!(
        Some(ErrorKind::UnexpectedEof),
        io_kind(&subscription.err().unwrap())
    );
    transport.refuse_dial().await;
}

#[tokio::test]
async fn a_terminal_header_error_stops_the_initial_connection() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .stop_on_error(signed_out)
        .header_provider(Bearer::signing_out_after(0))
        .build()
        .unwrap();

    let error = client.connect().await.unwrap_err();

    assert!(signed_out(&error), "{error}");
    assert!(signed_out(&client.err().unwrap()));
    transport.refuse_dial().await;
}

#[tokio::test]
async fn a_terminal_header_error_stops_a_reconnect() {
    let transport = FakeTransport::new();
    let bearer = Arc::new(Bearer::signing_out_after(1));
    let client = quick_backoff(builder(&transport))
        .stop_on_error(signed_out)
        .header_provider(Arc::clone(&bearer))
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.close();

    stopped(&client).await;
    assert!(signed_out(&client.err().unwrap()));
    assert_eq!(
        2,
        bearer.asked(),
        "expected one initial header and one failed reconnect header"
    );
    transport.refuse_dial().await;
}

#[tokio::test]
async fn max_attempts_stops_the_client() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport))
        .max_attempts(2)
        .build()
        .unwrap();

    let error = client.connect().await.unwrap_err();

    assert!(
        matches!(&error, Error::GaveUp { attempts: 2, last } if io_kind(last) == Some(ErrorKind::ConnectionRefused)),
        "expected the last attempt's error to be kept, got {error}"
    );
    stopped(&client).await;
    assert!(matches!(client.err(), Some(Error::GaveUp { .. })));
    transport.refuse_dial().await;
}

#[tokio::test]
async fn a_welcome_resets_the_attempt_count() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport))
        .max_attempts(3)
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;

    // Losing the connection is the first failed attempt of the outage, and the refused
    // redial the second. Had the failure before the welcome still counted, that would have
    // been the third.
    transport.fail_next_dial("connection refused");
    conn.close();

    transport.accept().await.welcome().await;
    assert!(
        client.err().is_none(),
        "a failure before the welcome counted against the outage after it"
    );
}

#[tokio::test]
async fn giving_up_tells_subscriptions_the_client_is_not_coming_back() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .max_attempts(1)
        .build()
        .unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;

    // Losing the connection is the only attempt allowed, so the client is done for, and
    // the subscription should hear that rather than a promise to return.
    conn.close();

    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );
    assert_eq!(
        Event::Disconnected {
            will_reconnect: false
        },
        next_event(&subscription).await,
        "the subscription was promised a reconnect the client was about to give up on"
    );
    stopped(&client).await;
    assert!(matches!(client.err(), Some(Error::GaveUp { .. })));
    transport.refuse_dial().await;
}

#[tokio::test]
async fn done_and_err_follow_the_client() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();

    assert!(
        client.err().is_none(),
        "a client that hasn't started has nothing to report"
    );
    let conn = welcomed(&client, &transport).await;
    assert!(
        client.err().is_none(),
        "a running client has nothing to report"
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(50), client.done())
            .await
            .is_err(),
        "done finished on a running client"
    );

    conn.push(r#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)
        .await;

    stopped(&client).await;
    assert!(matches!(
        client.err(),
        Some(Error::Disconnected {
            reason: Some(DisconnectReason::Unauthorized),
            reconnect: false,
        })
    ));
}

/// Where the Go client's `Connect` takes a context and stops the client when it ends, a
/// dropped future here bounds the wait and nothing else: the client is still dialing, and
/// a caller that has given up closes it.
#[tokio::test]
async fn a_connect_that_runs_out_of_time_leaves_the_client_dialing() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport)).build().unwrap();

    let gave_up = tokio::time::timeout(Duration::from_millis(20), client.connect()).await;

    assert!(gave_up.is_err(), "connect returned without a welcome");
    assert!(
        client.err().is_none(),
        "a dropped connect stopped the client"
    );
    assert_eq!(
        Some(ErrorKind::ConnectionRefused),
        io_kind(
            &client
                .last_error()
                .expect("what the last attempt failed on")
        ),
        "expected the client to say what it was waiting out"
    );

    let conn = transport.accept().await;
    conn.welcome().await;
    let subscription = subscribed(&client, &conn).await;

    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );

    client.close().await;
    assert!(matches!(client.err(), Some(Error::Closed)));
}

#[tokio::test]
async fn a_connect_that_runs_out_of_time_names_the_header_that_failed() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport))
        .header_provider(Bearer::signing_out_after(0))
        .build()
        .unwrap();

    let gave_up = tokio::time::timeout(Duration::from_millis(50), client.connect()).await;

    assert!(gave_up.is_err(), "connect returned without a welcome");
    let last = client
        .last_error()
        .expect("what the last attempt failed on");
    assert!(
        signed_out(&last),
        "expected the header error rather than a bare deadline, got {last}"
    );
    transport.refuse_dial().await;
}

#[tokio::test]
async fn the_first_connection_is_not_a_reconnect() {
    let transport = FakeTransport::new();
    transport.fail_next_dial("connection refused");
    let client = quick_backoff(builder(&transport)).build().unwrap();

    let connecting = connect(&client);
    let conn = transport.accept().await;
    conn.welcome().await;
    within(connecting).await.unwrap().unwrap();

    let subscription = subscribed(&client, &conn).await;

    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await,
        "a first connection that took two dials reported itself as a reconnect"
    );
}

#[tokio::test]
async fn a_failed_write_drops_the_connection_for_a_redial() {
    let transport = FakeTransport::new();
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let subscription = subscribed(&client, &conn).await;
    assert_eq!(
        Event::Connected { reconnected: false },
        next_event(&subscription).await
    );

    conn.fail_writes();
    assert!(matches!(
        subscription.perform("speak", ()).await,
        Err(Error::Transport(_))
    ));

    assert_eq!(
        Event::Disconnected {
            will_reconnect: true
        },
        next_event(&subscription).await
    );
    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.expect_command("subscribe", ROOM).await;
}

#[tokio::test]
async fn a_close_during_the_backoff_still_says_goodbye() {
    let transport = FakeTransport::new();
    let client = builder(&transport)
        .backoff(Duration::from_secs(60), Duration::from_secs(60))
        .build()
        .unwrap();
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
    transport.refuse_dial().await;

    client.close().await;

    assert_eq!(
        Event::Disconnected {
            will_reconnect: false
        },
        next_event(&subscription).await
    );
    assert_eq!(None, within(subscription.next_event()).await);
    assert_eq!(None, within(subscription.next()).await);
}

/// The welcome sets the client resubscribing both identifiers. With nobody reading yet it
/// is stuck mid-list on a write, which is when the unsubscribe arrives and queues up behind
/// it. Had it slipped in ahead of the second subscribe, the server would have been left
/// holding `OtherChannel` with no one here to answer for it.
#[tokio::test]
async fn an_unsubscribe_during_a_resubscribe_goes_out_after_it() {
    let transport = FakeTransport::new();
    transport.write_buffer(1);
    let client = quick_backoff(builder(&transport)).build().unwrap();
    let conn = welcomed(&client, &transport).await;
    let other = r#"{"channel":"OtherChannel"}"#;

    let _room = subscribed(&client, &conn).await;
    let subscribing = subscribe(&client, Identifier::new("OtherChannel"));
    conn.expect_command("subscribe", other).await;
    conn.confirm(other).await;
    let subscription = within(subscribing).await.unwrap().unwrap();

    conn.close();

    let reconnected = transport.accept().await;
    reconnected.welcome().await;
    reconnected.writing(2).await;
    let unsubscribing = tokio::spawn(async move { subscription.unsubscribe().await });
    tokio::time::sleep(Duration::from_millis(20)).await;

    let mut resubscribed = [reconnected.command().await, reconnected.command().await];
    resubscribed.sort_by(|left, right| left.identifier.cmp(&right.identifier));
    assert_eq!(
        vec!["subscribe", "subscribe"],
        resubscribed
            .iter()
            .map(|command| command.command.as_str())
            .collect::<Vec<_>>(),
        "expected both resubscribes before anything else"
    );
    assert_eq!(
        vec![other, ROOM],
        resubscribed
            .iter()
            .map(|command| command.identifier.as_str())
            .collect::<Vec<_>>()
    );
    reconnected.expect_command("unsubscribe", other).await;
    within(unsubscribing).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_message_for_nobody_is_dropped() {
    let transport = FakeTransport::new();
    let client = builder(&transport).build().unwrap();
    let conn = welcomed(&client, &transport).await;

    conn.push(&format!(
        r#"{{"identifier":{},"message":{{"body":"Hello?"}}}}"#,
        quote(ROOM)
    ))
    .await;
    conn.push("not even json").await;

    let subscription = subscribed(&client, &conn).await;
    assert!(
        tokio::time::timeout(Duration::from_millis(100), subscription.next())
            .await
            .is_err()
    );
    assert!(client.connected());
}
