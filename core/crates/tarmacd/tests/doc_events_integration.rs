// #326 / spec 2611.0003: `push` on a cli connection, and the `doc_event` it
// gives the app. The daemon's answers that need a held or counted resolve
// are in `state/tests/pushes.rs`.

mod common;

use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon, cli_open, none_within, write_doc};
use tarmac_protocol::{self as proto, MAX_FRAME_LEN, Msg, frame};

/// A daemon with a drained app and `d/dash.html` open on the active board,
/// under the registry's path.
fn with_open_card() -> (TestDaemon, Conn, String) {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&daemon.dir.join("d/dash.html"), "<p>dash</p>");
    cli_open(&daemon.sock, &doc);
    app.recv_doc_opened_for(&doc);
    (daemon, app, doc)
}

fn push(cli: &mut Conn, path: &str, value: &str) -> Msg {
    cli.send(&Msg::Push { path: path.into(), value: value.into() });
    cli.recv(Instant::now() + LONG, "the answer to a push")
}

fn recv_doc_event(app: &mut Conn) -> (String, String) {
    match app.recv_until("doc_event", |m| matches!(m, Msg::DocEvent { .. })) {
        Msg::DocEvent { path, value } => (path, value),
        _ => unreachable!(),
    }
}

// S45
#[test]
fn a_push_on_a_cli_connection_is_acked_and_given_to_the_app() {
    let (daemon, mut app, doc) = with_open_card();
    let mut cli = Conn::hello(&daemon.sock, "cli");

    assert_eq!(push(&mut cli, &doc, r#"{"n":1}"#), Msg::Ack);
    assert_eq!(recv_doc_event(&mut app), (doc, r#"{"n":1}"#.to_string()));
}

// S46: the app is read on a thread of its own, so the daemon's queue to it
// is what keeps the order.
#[test]
fn a_thousand_pushes_on_one_connection_reach_the_app_in_order() {
    let (daemon, mut app, doc) = with_open_card();
    let reader = std::thread::spawn(move || (0..1000).map(|_| recv_doc_event(&mut app)).collect::<Vec<_>>());
    let mut cli = Conn::hello(&daemon.sock, "cli");

    for n in 0..1000 {
        assert_eq!(push(&mut cli, &doc, &format!("{{\"n\":{n}}}")), Msg::Ack, "push {n}");
    }
    let expected: Vec<_> = (0..1000).map(|n| (doc.clone(), format!("{{\"n\":{n}}}"))).collect();
    assert_eq!(reader.join().unwrap(), expected);
}

// S24
#[test]
fn a_push_on_an_app_connection_is_ignored() {
    let (_daemon, mut app, doc) = with_open_card();

    app.send(&Msg::Push { path: doc.clone(), value: "1".into() });
    assert!(
        none_within(&mut app, Duration::from_millis(500), |m| matches!(m, Msg::Err { .. } | Msg::DocEvent { .. })),
        "the app got an answer to its push"
    );
    app.send(&Msg::DocRefresh { path: doc.clone() });
    app.recv_file_event_for(&doc);
}

// S50: `{t:"push", path:"/x", value:1}`.
#[test]
fn a_push_whose_value_is_not_a_string_is_a_malformed_frame_and_the_connection_goes_on() {
    let (daemon, _app, doc) = with_open_card();
    let mut cli = Conn::hello(&daemon.sock, "cli");
    let bad = [
        0x83, 0xa1, b't', 0xa4, b'p', b'u', b's', b'h', 0xa4, b'p', b'a', b't', b'h', 0xa2, b'/', b'x', 0xa5, b'v',
        b'a', b'l', b'u', b'e', 0x01,
    ];

    frame::write_sync(&mut cli.0, &bad).unwrap();
    match cli.recv(Instant::now() + LONG, "the answer to a malformed push") {
        Msg::Err { msg } => assert!(msg.starts_with("malformed frame"), "got: {msg}"),
        other => panic!("expected err, got {other:?}"),
    }
    assert_eq!(push(&mut cli, &doc, "1"), Msg::Ack);
}

/// A JSON string whose `push` to `path` is exactly `MAX_FRAME_LEN` bytes.
fn string_of_the_limit(path: &str) -> String {
    let encoded = |value: &str| proto::encode(&Msg::Push { path: path.into(), value: value.into() }).unwrap().len();
    let limit = MAX_FRAME_LEN as usize;
    let probe = format!("\"{}\"", "a".repeat(limit - 1000));
    let value = format!("\"{}\"", "a".repeat(limit - 1000 + limit - encoded(&probe)));
    assert_eq!(encoded(&value), limit);
    value
}

// S51
#[test]
fn a_value_whose_doc_event_is_over_the_frame_limit_is_refused_and_the_app_stays() {
    let (daemon, mut app, doc) = with_open_card();
    let value = string_of_the_limit(&doc);
    let event = proto::encode(&Msg::DocEvent { path: doc.clone(), value: value.clone() }).unwrap();
    assert!(event.len() > MAX_FRAME_LEN as usize);
    let mut cli = Conn::hello(&daemon.sock, "cli");

    assert_eq!(push(&mut cli, &doc, &value), Msg::Err { msg: "value is over the frame limit (16 MiB)".into() });
    assert_eq!(push(&mut cli, &doc, "1"), Msg::Ack);
    assert_eq!(recv_doc_event(&mut app), (doc, "1".to_string()));
}
