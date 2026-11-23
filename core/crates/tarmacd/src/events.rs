//! The daemon's facts for scripts (spec 2611.0012): one broadcast fan-out of
//! the `exit`, `bell`, `file_event` and `term_report` frames the app is told,
//! the last exits, and one subscriber's stream. It adds no watch and no state
//! to the app's view, and it never waits for a subscriber: one that falls
//! behind is told `lagged` and closed.

use std::collections::VecDeque;
use std::time::Duration;

use tarmac_protocol::{EventKind, Msg, frame};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use tokio::sync::broadcast::{self, error::RecvError};

/// The frames one subscriber can fall behind by. Above the app channel's 256,
/// because that one waits and this one does not: a look over a board with
/// many docs pushes a burst of `file_event`s.
pub(crate) const EVENTS_CAPACITY: usize = 1024;
const EXIT_RING: usize = 64;
const LAGGED_WRITE: Duration = Duration::from_secs(1);

fn is_event(msg: &Msg) -> bool {
    EventKind::of(msg).is_some()
}

pub(crate) struct Fanout(broadcast::Sender<Msg>);

impl Fanout {
    pub(crate) fn new(capacity: usize) -> Self {
        Fanout(broadcast::channel(capacity).0)
    }

    /// Nothing is cloned with no subscriber. `send` never waits; with no
    /// receiver left it fails, which is not an error here.
    pub(crate) fn publish(&self, msg: &Msg) {
        if !is_event(msg) || self.0.receiver_count() == 0 {
            return;
        }
        let _ = self.0.send(msg.clone());
    }

    pub(crate) fn subscribe(&self) -> broadcast::Receiver<Msg> {
        self.0.subscribe()
    }

    #[cfg(test)]
    fn receiver_count(&self) -> usize {
        self.0.receiver_count()
    }
}

/// The last `EXIT_RING` exits, bounded by count.
#[derive(Default)]
pub(crate) struct ExitRing(VecDeque<(String, Option<i64>)>);

impl ExitRing {
    pub(crate) fn record(&mut self, term_id: &str, code: Option<i64>) {
        self.0.push_back((term_id.to_owned(), code));
        if self.0.len() > EXIT_RING {
            self.0.pop_front();
        }
    }

    /// The code of the latest exit of `term_id`.
    #[expect(clippy::option_option, reason = "predates the lint; a design change, not part of #468")]
    pub(crate) fn lookup(&self, term_id: &str) -> Option<Option<i64>> {
        self.0.iter().rev().find(|(id, _)| id == term_id).map(|(_, code)| *code)
    }
}

pub(crate) struct Filter {
    kinds: Vec<EventKind>,
    term_id: Option<String>,
}

impl Filter {
    /// `kinds` names `exit`, `bell`, `changed` and `report`; `None` is all
    /// four. Unknown names are ignored; none known left is the `Err`.
    pub(crate) fn new(kinds: Option<Vec<String>>, term_id: Option<String>) -> Result<Filter, String> {
        let kinds: Vec<EventKind> = match kinds {
            None => EventKind::ALL.to_vec(),
            Some(names) => EventKind::ALL.into_iter().filter(|k| names.iter().any(|n| n == k.name())).collect(),
        };
        if kinds.is_empty() {
            return Err("no known event kind".into());
        }
        Ok(Filter { kinds, term_id })
    }

    pub(crate) fn wants(&self, kind: EventKind) -> bool {
        self.kinds.contains(&kind)
    }

    pub(crate) fn admits(&self, msg: &Msg) -> bool {
        EventKind::admits(&self.kinds, self.term_id.as_deref(), msg)
    }
}

/// A subscriber's start: what it receives from now on, its filter, and the
/// snapshot it is sent before `ack`.
pub(crate) struct Subscription {
    pub rx: broadcast::Receiver<Msg>,
    pub filter: Filter,
    pub snapshot: Vec<Msg>,
}

/// Writes the frames `filter` admits until the client closes, a write fails,
/// or the subscriber lags. The read arm is a plain `read`, which is
/// cancel-safe; a framed read would lose its bytes whenever a frame wins.
pub(crate) async fn serve(
    mut rx: broadcast::Receiver<Msg>,
    filter: &Filter,
    mut read: impl AsyncRead + Unpin,
    mut write: impl AsyncWrite + Unpin,
) {
    let mut sink = [0u8; 256];
    loop {
        tokio::select! {
            got = read.read(&mut sink) => {
                if matches!(got, Ok(0) | Err(_)) {
                    return;
                }
            }
            got = rx.recv() => match got {
                Ok(msg) => {
                    if filter.admits(&msg) && frame::write_msg_async(&mut write, &msg).await.is_err() {
                        return;
                    }
                }
                Err(RecvError::Lagged(_)) => {
                    let lagged = Msg::Err { msg: "lagged".into() };
                    let _ = tokio::time::timeout(LAGGED_WRITE, frame::write_msg_async(&mut write, &lagged)).await;
                    return;
                }
                Err(RecvError::Closed) => return,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tarmac_protocol::DocEntry;
    use tokio::io::{AsyncWriteExt, DuplexStream};

    fn bell(term_id: &str) -> Msg {
        Msg::Bell { term_id: term_id.into(), board_id: None }
    }

    fn exit(term_id: &str) -> Msg {
        Msg::Exit { term_id: term_id.into(), code: Some(0), board_id: None }
    }

    fn file_event() -> Msg {
        Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 }
    }

    fn term_report(term_id: &str) -> Msg {
        Msg::TermReport {
            term_id: term_id.into(),
            kind: None,
            text: None,
            at_ms: None,
            proc: None,
            read: false,
            board_id: None,
            cwd: None,
        }
    }

    fn not_events() -> Vec<Msg> {
        let doc = DocEntry {
            path: "/a.md".into(),
            via: "cli".into(),
            repo: None,
            repo_root: None,
            repo_color: None,
            read: true,
            last_changed_ms: None,
            last_opened_ms: None,
            term_id: None,
        };
        vec![
            Msg::Output { term_id: "t1".into(), bytes: b"x".to_vec() },
            Msg::TermProc { term_id: "t1".into(), name: "zsh".into(), pid: None },
            Msg::DocOpened(doc),
            Msg::BoardList { boards: vec![], active: "board-0".into() },
            Msg::DocEvent { path: "/a.md".into(), value: "1".into() },
            Msg::Err { msg: "x".into() },
        ]
    }

    fn names(names: &[&str]) -> Option<Vec<String>> {
        Some(names.iter().map(ToString::to_string).collect())
    }

    fn admitted(filter: &Filter, msgs: &[Msg]) -> Vec<Msg> {
        msgs.iter().filter(|m| filter.admits(m)).cloned().collect()
    }

    // S16
    #[test]
    fn no_filter_admits_the_four_event_frames_only() {
        let filter = Filter::new(None, None).unwrap();

        let events = [exit("t1"), bell("t1"), file_event(), term_report("t1")];
        assert_eq!(admitted(&filter, &events), events);
        assert_eq!(admitted(&filter, &not_events()), vec![]);
    }

    // S16
    #[test]
    fn a_kind_filter_admits_its_kinds_and_ignores_unknown_names() {
        let all = [exit("t1"), bell("t1"), file_event(), term_report("t1")];
        for (kinds, want) in [
            (names(&["exit"]), vec![exit("t1")]),
            (names(&["exit", "later"]), vec![exit("t1")]),
            (names(&["bell"]), vec![bell("t1")]),
            (names(&["changed"]), vec![file_event()]),
            (names(&["report"]), vec![term_report("t1")]),
        ] {
            assert_eq!(admitted(&Filter::new(kinds.clone(), None).unwrap(), &all), want, "{kinds:?}");
        }
    }

    // S16
    #[test]
    fn no_known_kind_is_refused() {
        for kinds in [names(&["later"]), names(&[])] {
            assert_eq!(Filter::new(kinds.clone(), None).err().as_deref(), Some("no known event kind"), "{kinds:?}");
        }
    }

    // S16
    #[test]
    fn a_terminal_filter_admits_that_terminal_and_no_file_event() {
        let filter = Filter::new(None, Some("t1".into())).unwrap();

        let all = [bell("t1"), bell("t2"), exit("t2"), term_report("t2"), file_event(), exit("t1")];
        assert_eq!(admitted(&filter, &all), vec![bell("t1"), exit("t1")]);
    }

    // S16
    #[test]
    fn output_is_not_an_event() {
        assert!(!is_event(&not_events()[0]));
        assert!([exit("t1"), bell("t1"), file_event(), term_report("t1")].iter().all(is_event));
    }

    // S17
    #[test]
    fn the_ring_keeps_the_last_64_exits() {
        let mut ring = ExitRing::default();
        for n in 1..=65 {
            ring.record(&format!("t{n}"), Some(n));
        }

        assert_eq!(ring.lookup("t1"), None);
        assert_eq!(ring.lookup("t2"), Some(Some(2)));
        assert_eq!(ring.lookup("t65"), Some(Some(65)));
    }

    // S17
    #[test]
    fn the_ring_gives_the_latest_exit_of_an_id() {
        let mut ring = ExitRing::default();
        ring.record("t1", Some(3));
        ring.record("t1", None);

        assert_eq!(ring.lookup("t1"), Some(None));
        assert_eq!(ring.lookup("t2"), None);
    }

    #[test]
    fn publish_sends_events_only() {
        let fanout = Fanout::new(8);
        let mut rx = fanout.subscribe();

        for msg in not_events() {
            fanout.publish(&msg);
        }
        fanout.publish(&bell("t1"));

        assert_eq!(rx.try_recv().unwrap(), bell("t1"));
        assert!(rx.try_recv().is_err());
    }

    /// `serve` on a task of its own, for every kind, with the client's end.
    fn served(fanout: &Fanout) -> (DuplexStream, tokio::task::JoinHandle<()>) {
        let (client, server) = tokio::io::duplex(4096);
        let rx = fanout.subscribe();
        (client, serve_on_task(rx, server))
    }

    /// `serve` of `rx` on `server`, on a task of its own, for every kind.
    fn serve_on_task(rx: broadcast::Receiver<Msg>, server: DuplexStream) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            let (read, write) = tokio::io::split(server);
            serve(rx, &Filter::new(None, None).unwrap(), read, write).await;
        })
    }

    async fn next_frame(client: &mut DuplexStream) -> std::io::Result<Msg> {
        let payload =
            tokio::time::timeout(Duration::from_secs(1), frame::read_async(client)).await.expect("a frame in 1 s")?;
        Ok(tarmac_protocol::decode(&payload).unwrap())
    }

    // S20
    #[tokio::test]
    async fn serve_ends_when_the_client_goes() {
        let fanout = Fanout::new(8);
        let (client, task) = served(&fanout);

        drop(client);

        tokio::time::timeout(Duration::from_secs(1), task).await.expect("serve ends in 1 s").unwrap();
        assert_eq!(fanout.receiver_count(), 0);
    }

    // S20
    #[tokio::test]
    async fn bytes_from_the_client_are_dropped_and_frames_go_on() {
        let fanout = Fanout::new(8);
        let (mut client, task) = served(&fanout);

        client.write_all(&[0, 0]).await.unwrap();
        tokio::task::yield_now().await;
        fanout.publish(&bell("t1"));
        assert_eq!(next_frame(&mut client).await.unwrap(), bell("t1"));

        client.write_all(&[0xff; 4]).await.unwrap();
        tokio::task::yield_now().await;
        fanout.publish(&exit("t1"));
        assert_eq!(next_frame(&mut client).await.unwrap(), exit("t1"));
        assert!(!task.is_finished());
    }

    // S21
    #[tokio::test]
    async fn a_subscriber_that_falls_behind_is_told_lagged_and_closed() {
        let fanout = Fanout::new(2);
        let (mut client, server) = tokio::io::duplex(4096);
        let rx = fanout.subscribe();
        for n in 1..=3 {
            fanout.publish(&bell(&format!("t{n}")));
        }

        let task = serve_on_task(rx, server);

        assert_eq!(next_frame(&mut client).await.unwrap(), Msg::Err { msg: "lagged".into() });
        assert_eq!(next_frame(&mut client).await.unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
        task.await.unwrap();
    }

    // S21: a client that reads nothing still has its stream closed, within
    // the limit of the `lagged` write (D7).
    #[tokio::test]
    async fn the_lagged_write_has_a_limit_when_the_client_reads_nothing() {
        let fanout = Fanout::new(2);
        let (_client, server) = tokio::io::duplex(8);
        let rx = fanout.subscribe();
        for n in 1..=3 {
            fanout.publish(&bell(&format!("t{n}")));
        }

        let task = serve_on_task(rx, server);

        tokio::time::timeout(LAGGED_WRITE + Duration::from_millis(500), task)
            .await
            .expect("serve ends after the limit")
            .unwrap();
    }
}
