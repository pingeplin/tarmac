//! Spec 2611.0003: `push`, as one cli connection makes it (`handle_push`),
//! with the connection's cache of resolved paths owned by the test.

use super::*;

type Cache = HashMap<PathBuf, PathBuf>;

/// `handle_push` on a task of its own, which gives the cache back.
async fn push(daemon: &Arc<Daemon>, cache: Cache, path: &Path, data: &str) -> (Result<(), String>, Cache) {
    let (daemon, path, data) = (daemon.clone(), path.to_str().unwrap().to_owned(), data.to_owned());
    answers(async move {
        let mut cache = cache;
        let answer = crate::docs::handle_push(&daemon, &mut cache, &path, data).await;
        (answer, cache)
    })
    .await
}

async fn push_once(daemon: &Arc<Daemon>, path: &Path, data: &str) -> Result<(), String> {
    push(daemon, Cache::new(), path, data).await.0
}

/// The `doc_event`s the app has now, each path as it is written: the app
/// keys its cards by the text.
fn doc_events(app: &mut mpsc::Receiver<Msg>) -> Vec<(String, String)> {
    let event = |msg| match msg {
        Msg::DocEvent { path, data } => Some((path, data)),
        _ => None,
    };
    pushed(app).into_iter().filter_map(event).collect()
}

/// `real/<file>` under its canonical path, and `link`, a symlink to `real`:
/// the doc's other spelling.
struct Linked {
    tmp: PathBuf,
    doc: PathBuf,
    linked: PathBuf,
    daemon: Arc<Daemon>,
    fs: Arc<StuckFs>,
    _release: std::sync::mpsc::Sender<()>,
}

impl Linked {
    /// `real/<file>`, open on no board.
    async fn written(tag: &str, file: &str) -> Self {
        let tmp = canon_tmp(tag);
        let doc = write_doc(tmp.join("real").join(file));
        std::os::unix::fs::symlink(tmp.join("real"), tmp.join("link")).unwrap();
        let (fs, release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone()).await;
        Linked { linked: tmp.join("link").join(file), tmp, doc, daemon, fs, _release: release }
    }

    /// `real/dash.html`, open on the active board.
    async fn open(tag: &str) -> Self {
        let linked = Linked::written(tag, "dash.html").await;
        open_doc(&linked.daemon, None, &linked.doc).await;
        linked
    }

    /// The registry's key, as it is written.
    fn key(&self) -> String {
        self.doc.to_str().unwrap().to_owned()
    }
}

impl Drop for Linked {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

fn nested(levels: usize) -> String {
    "[".repeat(levels) + &"]".repeat(levels)
}

// S17, and choice 14: each refusal as serde_json gives it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_text_that_is_not_one_json_value_is_refused_before_any_resolve() {
    let linked = Linked::open("push-not-json").await;
    let mut app = connect_app(&linked.daemon).await;
    let cases = [
        ("", "EOF while parsing a value at line 1 column 0"),
        ("{", "EOF while parsing an object at line 1 column 1"),
        ("1 2", "trailing characters at line 1 column 3"),
        (r#"{"a":1}x"#, "trailing characters at line 1 column 8"),
        ("\u{feff}1", "expected value at line 1 column 1"),
        ("1e400", "number out of range at line 1 column 5"),
        (r#""\ud800""#, "unexpected end of hex escape at line 1 column 8"),
        (&nested(128), "recursion limit exceeded at line 1 column 128"),
    ];
    for (data, why) in cases {
        let answer = push_once(&linked.daemon, &linked.linked, data).await;
        assert_eq!(answer, Err(format!("not one JSON value: {why}")), "{data:?}");
    }
    assert_eq!(linked.fs.calls(Call::Resolve), 0);
    assert_eq!(doc_events(&mut app), vec![]);
}

// S17, and choice 14: 127 levels are taken.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_json_value_is_taken_and_given_to_the_app_as_it_was_sent() {
    let linked = Linked::open("push-json").await;
    let mut app = connect_app(&linked.daemon).await;
    let values = ["1", r#""s""#, "null", r#"[1,{"a":[]}]"#, " {\"a\":1} \t", &nested(127)];
    for data in values {
        assert_eq!(push_once(&linked.daemon, &linked.doc, data).await, Ok(()), "{data:?}");
    }
    let expected: Vec<_> = values.iter().map(|data| (linked.key(), data.to_string())).collect();
    assert_eq!(doc_events(&mut app), expected);
}

// S18
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relative_path_is_refused() {
    let linked = Linked::open("push-relative").await;
    let answer = push_once(&linked.daemon, Path::new("real/dash.html"), "1").await;
    assert_eq!(answer, Err("path is not absolute: real/dash.html".into()));
}

// Choice 1: the JSON check comes first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relative_path_with_a_text_that_is_not_json_is_refused_for_the_text() {
    let linked = Linked::open("push-order").await;
    let answer = push_once(&linked.daemon, Path::new("real/dash.html"), "{").await;
    assert_eq!(answer, Err("not one JSON value: EOF while parsing an object at line 1 column 1".into()));
}

// S19
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_push_to_another_spelling_of_the_doc_names_the_registry_path() {
    let linked = Linked::open("push-symlink").await;
    let mut app = connect_app(&linked.daemon).await;

    assert_eq!(push_once(&linked.daemon, &linked.linked, r#"{"n":1}"#).await, Ok(()));
    assert_eq!(doc_events(&mut app), vec![(linked.key(), r#"{"n":1}"#.into())]);
}

// Choice 3: `Path` equality takes `/./`, `//` and a trailing `/` for the
// key, but the app keys its cards by the key's text.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_names_the_registry_key_as_it_is_written() {
    let linked = Linked::open("push-key-text").await;
    let mut app = connect_app(&linked.daemon).await;
    let key = linked.key();
    let spellings = [key.replace("/real/", "/real/./"), key.replacen('/', "//", 1), format!("{key}/")];

    for spelling in &spellings {
        assert_eq!(push_once(&linked.daemon, Path::new(spelling), "1").await, Ok(()), "{spelling}");
    }
    assert_eq!(doc_events(&mut app), vec![(key, "1".to_string()); spellings.len()]);
    assert_eq!(linked.fs.calls(Call::Resolve), 0);
}

// S20
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_connection_resolves_a_spelling_once() {
    let linked = Linked::open("push-cache").await;
    let _app = connect_app(&linked.daemon).await;

    let (answer, cache) = push(&linked.daemon, Cache::new(), &linked.linked, "1").await;
    assert_eq!(answer, Ok(()));
    assert_eq!(push(&linked.daemon, cache, &linked.linked, "2").await.0, Ok(()));
    assert_eq!(linked.fs.calls(Call::Resolve), 1, "one cache");

    assert_eq!(push_once(&linked.daemon, &linked.linked, "3").await, Ok(()));
    assert_eq!(linked.fs.calls(Call::Resolve), 2, "a new cache");

    assert_eq!(push_once(&linked.daemon, &linked.doc, "4").await, Ok(()));
    assert_eq!(linked.fs.calls(Call::Resolve), 2, "the registry's own spelling");
}

// Choice 19
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resolve_that_fails_is_made_again() {
    let linked = Linked::open("push-no-file").await;
    let missing = linked.tmp.join("real/none.html");

    let (answer, cache) = push(&linked.daemon, Cache::new(), &missing, "1").await;
    assert!(answer.is_err());
    assert!(push(&linked.daemon, cache, &missing, "2").await.0.is_err());
    assert_eq!(linked.fs.calls(Call::Resolve), 2);
}

// S21
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_closed_mid_stream_is_refused_whatever_the_cache_holds() {
    let linked = Linked::open("push-closed").await;
    let mut app = connect_app(&linked.daemon).await;
    let (answer, cache) = push(&linked.daemon, Cache::new(), &linked.linked, "1").await;
    assert_eq!(answer, Ok(()));
    doc_events(&mut app);

    assert!(linked.daemon.close_doc(&linked.doc).await);
    let answer = push(&linked.daemon, cache, &linked.linked, "2").await.0;
    assert_eq!(answer, Err(format!("not an open doc: {}", linked.linked.display())));
    assert_eq!(doc_events(&mut app), vec![]);
}

// S22
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_on_a_board_in_the_background_gets_its_event() {
    let linked = Linked::written("push-background", "dash.html").await;
    let mut app = connect_app(&linked.daemon).await;
    let other = linked.daemon.boards.lock().await.create();
    open_doc(&linked.daemon, Some(&other), &linked.doc).await;
    linked.daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);

    assert_eq!(push_once(&linked.daemon, &linked.doc, "1").await, Ok(()));
    assert_eq!(doc_events(&mut app), vec![(linked.key(), "1".into())]);
}

// S22
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_on_two_boards_gets_one_event() {
    let linked = Linked::open("push-two-boards").await;
    let mut app = connect_app(&linked.daemon).await;
    let other = linked.daemon.boards.lock().await.create();
    open_doc(&linked.daemon, Some(&other), &linked.doc).await;

    assert_eq!(push_once(&linked.daemon, &linked.doc, "1").await, Ok(()));
    assert_eq!(doc_events(&mut app), vec![(linked.key(), "1".into())]);
}

// S23: the daemon does not know a doc's kind as the app sees it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_markdown_doc_gets_its_event_too() {
    let linked = Linked::written("push-markdown", "notes.md").await;
    let mut app = connect_app(&linked.daemon).await;
    open_doc(&linked.daemon, None, &linked.doc).await;

    assert_eq!(push_once(&linked.daemon, &linked.doc, "1").await, Ok(()));
    assert_eq!(doc_events(&mut app), vec![(linked.key(), "1".into())]);
}

// S47
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_push_with_no_app_is_refused() {
    let linked = Linked::open("push-no-app").await;
    let answer = push_once(&linked.daemon, &linked.doc, "1").await;
    assert_eq!(answer, Err("no app is connected".into()));
}

// S48
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_that_is_not_an_open_doc_is_refused() {
    let linked = Linked::open("push-not-open").await;
    let mut app = connect_app(&linked.daemon).await;
    let other = write_doc(linked.tmp.join("real/other.html"));

    let answer = push_once(&linked.daemon, &other, "1").await;
    assert_eq!(answer, Err(format!("not an open doc: {}", other.display())));
    assert_eq!(doc_events(&mut app), vec![]);
}

// S48
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_path_with_no_file_gets_the_resolve_text() {
    let linked = Linked::open("push-missing").await;
    let missing = linked.tmp.join("real/none.html");

    let answer = push_once(&linked.daemon, &missing, "1").await;
    assert_eq!(answer, Err(format!("cannot open {}: No such file or directory (os error 2)", missing.display())));
}

// S49
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_push_whose_resolve_does_not_answer_fails_in_its_limit() {
    let linked = Linked::open("push-stuck").await;
    linked.fs.hold(Call::Resolve, &linked.tmp.join("link"));

    let before = std::time::Instant::now();
    let answer = push_once(&linked.daemon, &linked.linked, "1").await;
    assert_eq!(answer, did_not_answer(&linked.daemon, &linked.linked));
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
}
