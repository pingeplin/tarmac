//! Spec 2611.0005: the directory of a data file under the doc's own is
//! counted and watched as a doc's directory is.

use super::*;
use crate::boards::DEFAULT_BOARD_ID;

/// `doc_data` for `doc` of `board`, as the daemon handles it.
async fn name_on(daemon: &Daemon, board: &str, doc: &Path, data: Option<&Path>) -> bool {
    crate::docs::record_data(daemon, board, doc, data.map(Path::to_path_buf)).await
}

async fn name(daemon: &Daemon, doc: &Path, data: Option<&Path>) -> bool {
    name_on(daemon, DEFAULT_BOARD_ID, doc, data).await
}

/// A connection takes the app's place: its generation, and its pushes.
async fn take_the_place(daemon: &Daemon) -> (u64, mpsc::Receiver<Msg>) {
    let (tx, rx) = mpsc::channel(16);
    let (generation, _) = daemon.install_app(tx, None).await;
    (generation, rx)
}

fn watches(calls: &SourceCalls) -> usize {
    calls.0.lock().unwrap().iter().filter(|(change, _)| *change == Change::Watch).count()
}

/// `<tmp>/d/dash.html` open on board-0 of a daemon on `source`, whose gate
/// calls `fs`, and an app that the open's look has reached.
struct Card {
    tmp: PathBuf,
    dir: PathBuf,
    dash: PathBuf,
    daemon: Arc<Daemon>,
    app: mpsc::Receiver<Msg>,
    /// The generation of the connection that holds the app's place.
    generation: u64,
    fs: Arc<StuckFs>,
    release: std::sync::mpsc::Sender<()>,
}

impl Card {
    /// `tmp` is canonical (`canon_tmp`).
    async fn on(tmp: PathBuf, source: Box<dyn WakeSource>) -> Self {
        Card::within(tmp, source, LIMIT).await
    }

    /// `on`, with a gate that waits `limit` for each call: a test that lets
    /// a held call go is then sure it returns in time.
    async fn within(tmp: PathBuf, source: Box<dyn WakeSource>, limit: Duration) -> Self {
        let dir = tmp.join("d");
        let dash = write_doc(dir.join("dash.html"));
        let (fs, release) = stuck_fs();
        let daemon = Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Wake::default()), fs.clone(), limit).await;
        let (generation, mut app) = take_the_place(&daemon).await;
        open_doc(&daemon, None, &dash).await;
        flushed(&mut app, &dash).await;
        Card { tmp, dir, dash, daemon, app, generation, fs, release }
    }

    async fn silent(tag: &str) -> Self {
        Card::on(canon_tmp(tag), Box::new(Silent)).await
    }

    /// Writes `name` under the card's directory, names it for `dash`, and
    /// takes the answer.
    async fn reading(&mut self, name: &str) -> PathBuf {
        let file = write_doc(self.dir.join(name));
        assert!(crate::docs::record_data(&self.daemon, DEFAULT_BOARD_ID, &self.dash, Some(file.clone())).await);
        assert_eq!(next_change(&mut self.app).await.0, file, "the answer");
        file
    }

    async fn watched(&self, dir: &Path) -> bool {
        watched(&self.daemon, dir).await
    }

    /// Lets go each call that `fs` holds, and each later one.
    fn let_go(&mut self) {
        self.release = std::sync::mpsc::channel().0;
    }
}

impl Drop for Card {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

// S8a. The doc's own open is the one watch.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_data_that_is_refused_asks_for_no_watch() {
    let (source, calls, _release) = held_source(&[]);
    let card = Card::on(canon_tmp("s8a"), source).await;
    let (d, tmp) = (card.dir.display().to_string(), card.tmp.display().to_string());
    for file in ["d/x.json", "d/sub/x.json", "x.json", "away/x.json", "dx/x.json"] {
        write_doc(card.tmp.join(file));
    }
    let sent = [
        format!("{d}/sub/../x.json"),
        format!("{d}/../x.json"),
        format!("{d}/sub/../../away/x.json"),
        format!("{d}/./x.json"),
        format!("{d}/sub/./x.json"),
        format!("{d}//sub/x.json"),
        format!("{d}/sub/x.json/"),
        format!("{d}x/x.json"),
        d.clone(),
        format!("{tmp}/x.json"),
        "sub/x.json".to_string(),
    ];
    for data in &sent {
        assert!(!name(&card.daemon, &card.dash, Some(Path::new(data))).await, "{data}");
    }
    let doubled = PathBuf::from(format!("{tmp}//d/dash.html"));
    let under_doubled = PathBuf::from(format!("{tmp}//d/sub/x.json"));
    assert!(!name(&card.daemon, &doubled, Some(&under_doubled)).await, "a doc written with //");

    assert_eq!(watches(&calls), 1, "the doc's directory only");
    for dir in [card.dir.join("sub"), card.tmp.clone(), card.tmp.join("away"), card.tmp.join("dx")] {
        assert!(!card.watched(&dir).await, "{}", dir.display());
    }
}

// S8b
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_data_that_is_refused_leaves_the_registration_and_its_count() {
    let mut card = Card::silent("s8b").await;
    card.reading("sub/stats.json").await;
    let two = write_doc(card.dir.join("two/x.json"));
    let (sub, two_dir) = (card.dir.join("sub"), card.dir.join("two"));

    let through = card.dir.join("sub/../two/x.json");
    assert!(!name(&card.daemon, &card.dash, Some(&through)).await);
    assert!(!name(&card.daemon, &card.dir.join("nope.html"), Some(&two)).await);
    assert!(!name_on(&card.daemon, "board-9", &card.dash, Some(&two)).await);
    assert!(card.watched(&sub).await);
    assert!(!card.watched(&two_dir).await);

    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&sub).await);
}

// S14a
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_watch_that_fails_is_tried_again_at_a_wake_of_the_file_system_only() {
    let tmp = canon_tmp("s14a");
    let sub = tmp.join("d/sub");
    let calls = Arc::new(SourceCalls::default());
    let mut card = Card::on(tmp, Box::new(WatchFails(sub.clone(), calls.clone()))).await;
    let stats = write_doc(sub.join("stats.json"));

    let changed = change(&card.dash);
    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert_eq!(next_change(&mut card.app).await.0, stats, "the answer");
    assert_eq!(calls.of(Change::Watch, &sub), 1);
    assert_eq!(next_change(&mut card.app).await, (card.dash.clone(), changed), "the look the failed watch woke");

    let stamps = card.fs.calls(Call::Stamp);
    tokio::time::sleep(4 * crate::watch::BURST).await;
    assert_eq!(card.fs.calls(Call::Stamp), stamps, "no further look");
    assert_eq!(calls.of(Change::Watch, &sub), 1, "no further try");

    card.daemon.wake.from_fs();
    eventually("a second try", || calls.of(Change::Watch, &sub) == 2).await;
    tokio::time::sleep(4 * crate::watch::BURST).await;
    assert_eq!(calls.of(Change::Watch, &sub), 2, "one try for one wake");

    for tries in [3, 4] {
        card.daemon.wake.from_fs();
        eventually("the next try", || calls.of(Change::Watch, &sub) == tries).await;
    }
}

// S14d
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_same_name_again_tries_a_directory_that_is_wanted() {
    let card = Card::silent("s14d").await;
    let sub = card.dir.join("sub");
    let stats = sub.join("stats.json");
    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    std::fs::create_dir(&sub).unwrap();

    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert!(card.watched(&sub).await);
}

// S14e
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_registration_cleared_during_its_try_keeps_nothing_of_it() {
    let mut card = Card::within(canon_tmp("s14e"), Box::new(Silent), Duration::from_secs(30)).await;
    let sub = card.dir.join("sub");
    assert!(name(&card.daemon, &card.dash, Some(&sub.join("stats.json"))).await);
    std::fs::create_dir(&sub).unwrap();
    card.fs.hold(Call::ResolveDir, &sub);

    let changed = change(&card.dash);
    card.daemon.wake.from_fs();
    eventually("the try's held resolve", || card.fs.held(Call::ResolveDir) == 1).await;
    assert!(name(&card.daemon, &card.dash, None).await);
    card.let_go();
    assert_eq!(next_change(&mut card.app).await, (card.dash.clone(), changed), "the look after the try");
    assert!(!card.watched(&sub).await);
}

// S17
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_subdirectory_is_watched_while_a_doc_reads_a_file_in_it() {
    let mut card = Card::silent("s17").await;
    let stats = card.reading("sub/stats.json").await;
    let sub = card.dir.join("sub");
    assert!(card.watched(&sub).await);

    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&sub).await);
    change(&stats);
    look_at(&card.daemon).await;
    assert_eq!(file_events(&mut card.app), vec![]);
}

// S18
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn another_name_moves_the_count_to_its_directory() {
    let mut card = Card::silent("s18").await;
    card.reading("sub/stats.json").await;
    let (sub, two) = (card.dir.join("sub"), card.dir.join("two"));

    card.reading("two/x.json").await;
    assert!(card.watched(&two).await);
    assert!(!card.watched(&sub).await);

    card.reading("x.json").await;
    assert!(!card.watched(&two).await);
    assert!(card.watched(&card.dir).await);
}

// S19
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_same_name_again_counts_nothing_more() {
    let mut card = Card::silent("s19").await;
    let stats = card.reading("sub/stats.json").await;
    let resolves = card.fs.calls(Call::ResolveDir);
    for _ in 0..2 {
        assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
        assert_eq!(next_change(&mut card.app).await.0, stats);
    }
    assert_eq!(card.fs.calls(Call::ResolveDir), resolves, "no directory is resolved again");
    let sub = card.dir.join("sub");
    assert!(card.watched(&sub).await);

    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&sub).await);
}

// S20
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_subdirectory_two_docs_read_in_is_watched_until_both_name_none() {
    let mut card = Card::silent("s20").await;
    let dash2 = write_doc(card.dir.join("dash2.html"));
    open_doc(&card.daemon, None, &dash2).await;
    card.reading("sub/a.json").await;
    let b = write_doc(card.dir.join("sub/b.json"));
    assert!(name(&card.daemon, &dash2, Some(&b)).await);
    let sub = card.dir.join("sub");

    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(card.watched(&sub).await);
    assert!(name(&card.daemon, &dash2, None).await);
    assert!(!card.watched(&sub).await);
}

// S21
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn closing_the_doc_gives_back_the_count_of_its_data_directory() {
    let mut card = Card::silent("s21").await;
    card.reading("sub/stats.json").await;
    open_doc(&card.daemon, None, &write_doc(card.dir.join("other.md"))).await;
    let sub = card.dir.join("sub");
    assert!(card.watched(&sub).await);

    assert!(card.daemon.close_doc(&card.dash).await);
    assert!(!card.watched(&sub).await);
    assert!(card.watched(&card.dir).await);
}

// S21a
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_doc_closed_while_its_data_directory_is_counted_gives_the_count_back() {
    let mut card = Card::within(canon_tmp("s21a"), Box::new(Silent), Duration::from_secs(30)).await;
    let sub = card.dir.join("sub");
    let stats = write_doc(sub.join("stats.json"));
    card.fs.hold(Call::ResolveDir, &sub);

    let naming = {
        let (daemon, dash) = (card.daemon.clone(), card.dash.clone());
        tokio::spawn(async move { name(&daemon, &dash, Some(&stats)).await })
    };
    eventually("the held resolve", || card.fs.held(Call::ResolveDir) == 1).await;
    assert!(card.daemon.close_doc(&card.dash).await);
    card.let_go();
    assert!(!within(naming).await, "the doc is gone");
    assert!(!card.watched(&sub).await);
}

// S22
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn deleting_the_board_gives_back_the_count_of_a_data_directory() {
    let card = Card::silent("s22").await;
    let other = card.daemon.boards.lock().await.create();
    let dash1 = write_doc(card.dir.join("dash1.html"));
    open_doc(&card.daemon, Some(&other), &dash1).await;
    let stats = write_doc(card.dir.join("sub/stats.json"));
    assert!(name_on(&card.daemon, &other, &dash1, Some(&stats)).await);
    let sub = card.dir.join("sub");
    assert!(card.watched(&sub).await);

    assert!(card.daemon.delete_board(&other).await);
    assert!(!card.watched(&sub).await);
}

// S23
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_open_in_the_subdirectory_keeps_its_own_count() {
    let mut card = Card::silent("s23").await;
    card.reading("sub/stats.json").await;
    let notes = write_doc(card.dir.join("sub/notes.md"));
    open_doc(&card.daemon, None, &notes).await;
    let sub = card.dir.join("sub");

    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(card.watched(&sub).await);
    assert!(card.daemon.close_doc(&notes).await);
    assert!(!card.watched(&sub).await);
}

// S24
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_beside_the_doc_counts_nothing() {
    let mut card = Card::silent("s24").await;
    card.reading("stats.json").await;
    assert!(card.daemon.close_doc(&card.dash).await);
    assert!(!card.watched(&card.dir).await);

    open_doc(&card.daemon, None, &card.dash).await;
    card.reading("stats.json").await;
    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(card.watched(&card.dir).await);
}

// S25
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_of_a_board_in_the_background_counts_its_data_directory() {
    let mut card = Card::silent("s25").await;
    card.daemon.boards.lock().await.create();
    let stats = write_doc(card.dir.join("sub/stats.json"));

    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert!(card.watched(&card.dir.join("sub")).await);
    look_at(&card.daemon).await;
    assert_eq!(file_events(&mut card.app), vec![]);
}

// S27. The harness of `an_open_reports_a_change_that_no_wake_told_of`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_data_that_makes_a_watch_reports_a_change_that_no_wake_told_of() {
    let mut card = Card::silent("s27").await;
    let kept = write_doc(card.tmp.join("kept/a.md"));
    open_doc(&card.daemon, None, &kept).await;
    flushed(&mut card.app, &kept).await;
    let stats = write_doc(card.dir.join("sub/stats.json"));

    let changed = change(&kept);
    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert!(file_events(&mut card.app).contains(&(kept, changed)));
}

// S28, the restart. The data file is not in the state file (S28 [it]).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_watches_no_data_directory_until_a_doc_data_names_the_file() {
    let tmp = canon_tmp("s28");
    let dash = write_doc(tmp.join("d/dash.html"));
    let stats = write_doc(tmp.join("d/sub/stats.json"));
    let sub = tmp.join("d/sub");
    std::fs::write(tmp.join("state.json"), state_with_docs(&[&dash])).unwrap();
    let (source, calls, _release) = held_source(&[]);
    let (fs, _unheld) = stuck_fs();
    let daemon = held(&tmp, source, fs).await;

    assert!(!watched(&daemon, &sub).await);
    assert_eq!(calls.of(Change::Watch, &sub), 0);
    assert!(name(&daemon, &dash, Some(&stats)).await);
    assert!(watched(&daemon, &sub).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

/// Every call the gate made, of each kind.
fn gate_calls(fs: &StuckFs) -> Vec<u32> {
    [Call::Resolve, Call::ResolveDir, Call::Stamp, Call::RepoOf, Call::IsDir, Call::PidCwd].map(|c| fs.calls(c)).to_vec()
}

/// A change of `doc`, a wake given as the file system's, and that wake's
/// look: a try that it made has ended.
async fn wake_from_fs(card: &mut Card, doc: &Path) {
    let changed = change(doc);
    card.daemon.wake.from_fs();
    assert_eq!(next_change(&mut card.app).await, (doc.to_owned(), changed), "the look of the wake");
}

// S14. `sub` is not there, then a regular file.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_directory_that_is_not_there_is_not_tried_until_a_wake() {
    for sub_is_a_file in [false, true] {
        let (source, calls, _release) = held_source(&[]);
        let card = Card::on(canon_tmp("s14"), source).await;
        let sub = card.dir.join("sub");
        if sub_is_a_file {
            write_doc(sub.clone());
        }

        assert!(name(&card.daemon, &card.dash, Some(&sub.join("stats.json"))).await);
        let made = gate_calls(&card.fs);
        tokio::time::sleep(4 * crate::watch::BURST).await;
        assert_eq!(gate_calls(&card.fs), made, "no further call, a file: {sub_is_a_file}");
        assert_eq!(calls.of(Change::Watch, &sub), 0, "a file: {sub_is_a_file}");
    }
}

// S14b
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_directory_made_later_is_watched_at_a_wake_of_the_file_system() {
    let mut card = Card::silent("s14b").await;
    let sub = card.dir.join("sub");
    assert!(name(&card.daemon, &card.dash, Some(&sub.join("stats.json"))).await);
    std::fs::create_dir(&sub).unwrap();
    let dash = card.dash.clone();
    wake_from_fs(&mut card, &dash).await;
    assert!(card.watched(&sub).await);
    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&sub).await);

    let (source, calls, _release) = held_source(&[]);
    let mut card = Card::on(canon_tmp("s14b-cleared"), source).await;
    let sub = card.dir.join("sub");
    assert!(name(&card.daemon, &card.dash, Some(&sub.join("stats.json"))).await);
    assert!(name(&card.daemon, &card.dash, None).await);
    std::fs::create_dir(&sub).unwrap();
    let dash = card.dash.clone();
    wake_from_fs(&mut card, &dash).await;
    assert!(!card.watched(&sub).await);
    assert_eq!(calls.of(Change::Watch, &sub), 0);
}

// S14c. The resolve of `sub` does not return. Only that call is held: a
// stamp of the data file held too would leave its key busy, and a look skips
// a busy key with no call (`PathGate::stamps`), so nothing could show that
// the registration stands.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_data_directory_whose_resolve_does_not_answer_is_watched_when_it_returns() {
    let mut card = Card::silent("s14c").await;
    let sub = card.dir.join("sub");
    let stats = write_doc(sub.join("stats.json"));
    card.fs.hold(Call::ResolveDir, &sub);

    let before = std::time::Instant::now();
    let (daemon, dash, data) = (card.daemon.clone(), card.dash.clone(), stats.clone());
    assert!(answers(async move { name(&daemon, &dash, Some(&data)).await }).await);
    assert!(before.elapsed() < 2 * LIMIT, "it waited {:?}", before.elapsed());
    assert_eq!(next_change(&mut card.app).await.0, stats, "the answer");
    assert_eq!(card.fs.held(Call::ResolveDir), 1);
    assert!(!card.watched(&sub).await);
    let changed = change(&stats);
    look_at(&card.daemon).await;
    assert_eq!(file_events(&mut card.app), vec![(stats.clone(), changed)], "the registration stands");

    card.let_go();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !card.watched(&sub).await {
        assert!(std::time::Instant::now() < deadline, "sub is never watched");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

// S29a
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_path_through_a_link_to_the_doc_directory_counts_nothing() {
    let (source, calls, _release) = held_source(&[]);
    let card = Card::on(canon_tmp("s29a"), source).await;
    open_doc(&card.daemon, None, &write_doc(card.dir.join("other.md"))).await;
    std::os::unix::fs::symlink(".", card.dir.join("self")).unwrap();
    write_doc(card.dir.join("stats.json"));

    assert!(name(&card.daemon, &card.dash, Some(&card.dir.join("self/stats.json"))).await);
    assert_eq!(calls.of(Change::Watch, &card.dir.join("self")), 0);
    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(card.watched(&card.dir).await);
    assert_eq!(calls.of(Change::Unwatch, &card.dir), 0);
    assert_eq!(calls.of(Change::Unwatch, &card.dir.join("self")), 0);
}

// S30
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_path_through_a_link_out_of_the_tree_watches_nothing() {
    let (source, calls, _release) = held_source(&[]);
    let card = Card::on(canon_tmp("s30"), source).await;
    let away = card.tmp.join("away");
    write_doc(away.join("stats.json"));
    std::os::unix::fs::symlink(&away, card.dir.join("out")).unwrap();

    assert!(name(&card.daemon, &card.dash, Some(&card.dir.join("out/stats.json"))).await);
    assert_eq!(watches(&calls), 1, "the doc's directory only");
    assert!(!card.watched(&card.dir.join("out")).await);
    assert!(!card.watched(&away).await);
    assert!(name(&card.daemon, &card.dash, None).await);
    assert_eq!(calls.0.lock().unwrap().iter().filter(|(c, _)| *c == Change::Unwatch).count(), 0);
    assert!(card.watched(&card.dir).await);
}

/// `<dir>/in`, a link to `<dir>/real`, which holds `stats.json`, named for
/// the card's doc.
async fn reading_through_in(card: &mut Card) -> PathBuf {
    let real = card.dir.join("real");
    write_doc(real.join("stats.json"));
    std::os::unix::fs::symlink(&real, card.dir.join("in")).unwrap();
    let named = card.dir.join("in/stats.json");
    assert!(name(&card.daemon, &card.dash, Some(&named)).await);
    assert_eq!(next_change(&mut card.app).await.0, named, "the answer names the path as sent");
    real
}

// S31a
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_path_through_a_link_in_the_tree_watches_the_directory_it_leads_to() {
    let (source, calls, _release) = held_source(&[]);
    let mut card = Card::on(canon_tmp("s31a"), source).await;
    let real = reading_through_in(&mut card).await;

    assert_eq!(calls.of(Change::Watch, &real), 1);
    assert_eq!(calls.of(Change::Watch, &card.dir.join("in")), 0);
    assert!(card.watched(&real).await);
    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&real).await);
    assert_eq!(calls.of(Change::Watch, &card.dir.join("in")), 0);
}

// S31b
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_count_is_given_back_for_the_directory_it_was_taken_for() {
    let (source, calls, _release) = held_source(&[]);
    let mut card = Card::on(canon_tmp("s31b"), source).await;
    let real = reading_through_in(&mut card).await;
    let real2 = card.dir.join("real2");
    std::fs::create_dir(&real2).unwrap();
    assert!(card.watched(&real).await);

    std::fs::remove_file(card.dir.join("in")).unwrap();
    std::os::unix::fs::symlink(&real2, card.dir.join("in")).unwrap();
    assert!(name(&card.daemon, &card.dash, None).await);
    assert!(!card.watched(&real).await);
    assert!(!card.watched(&real2).await);
    assert_eq!(calls.of(Change::Watch, &real2), 0);
}

// S34a
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_data_path_through_a_link_to_a_hidden_directory_watches_nothing() {
    let (source, calls, _release) = held_source(&[]);
    let card = Card::on(canon_tmp("s34a"), source).await;
    let cfg = card.dir.join(".cfg");
    write_doc(cfg.join("x.json"));
    std::os::unix::fs::symlink(&cfg, card.dir.join("data")).unwrap();

    assert!(name(&card.daemon, &card.dash, Some(&card.dir.join("data/x.json"))).await);
    for dir in [cfg, card.dir.join("data")] {
        assert_eq!(calls.of(Change::Watch, &dir), 0, "{}", dir.display());
        assert!(!card.watched(&dir).await, "{}", dir.display());
    }
}

// S26
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_end_of_the_app_drops_every_data_registration_of_every_board() {
    let mut card = Card::silent("s26").await;
    let stats = card.reading("sub/stats.json").await;
    let background = card.daemon.boards.lock().await.create();
    card.daemon.boards.lock().await.set_active(DEFAULT_BOARD_ID);
    let bg_dash = write_doc(card.dir.join("bg.html"));
    open_doc(&card.daemon, Some(&background), &bg_dash).await;
    let bg_data = write_doc(card.dir.join("bg/x.json"));
    assert!(name_on(&card.daemon, &background, &bg_dash, Some(&bg_data)).await);
    let (sub, bg) = (card.dir.join("sub"), card.dir.join("bg"));
    assert!(card.watched(&sub).await);
    assert!(card.watched(&bg).await);

    card.daemon.remove_app(card.generation).await;
    assert!(!card.watched(&sub).await);
    assert!(!card.watched(&bg).await);

    let (_, mut next) = take_the_place(&card.daemon).await;
    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert!(card.watched(&sub).await);
    assert_eq!(next_change(&mut next).await.0, stats);
}

// S26a. Only this harness can put B's frames and A's end in a set order:
// `conn::handshake` sends `hello_ok` before `app_session` takes the place.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_end_of_an_app_that_lost_its_place_drops_nothing() {
    for a_ends_first in [false, true] {
        let mut card = Card::silent("s26a").await;
        let stats = card.reading("sub/stats.json").await;
        let sub = card.dir.join("sub");

        let (_, mut b) = take_the_place(&card.daemon).await;
        assert!(!card.watched(&sub).await, "B took the place, A ends first: {a_ends_first}");
        if a_ends_first {
            card.daemon.remove_app(card.generation).await;
        }
        assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
        assert_eq!(next_change(&mut b).await.0, stats);
        if !a_ends_first {
            card.daemon.remove_app(card.generation).await;
        }

        assert!(card.watched(&sub).await, "A ends first: {a_ends_first}");
        let changed = change(&stats);
        look_at(&card.daemon).await;
        assert_eq!(file_events(&mut b), vec![(stats, changed)], "A ends first: {a_ends_first}");
    }
}

// S26c. The name is in flight, with no count of its own (it was held), when
// another connection takes the place and drops the registration.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_name_in_flight_when_the_place_is_taken_leaves_the_new_apps_name_counted() {
    let mut card = Card::silent("s26c").await;
    let stats = card.reading("sub/stats.json").await;
    let sub = card.dir.join("sub");
    card.fs.hold(Call::Stamp, &sub);

    let again = {
        let (daemon, dash, stats) = (card.daemon.clone(), card.dash.clone(), stats.clone());
        tokio::spawn(async move { name(&daemon, &dash, Some(&stats)).await })
    };
    eventually("the held stamp", || card.fs.held(Call::Stamp) == 1).await;
    let (_, mut b) = take_the_place(&card.daemon).await;
    card.let_go();
    assert!(within(again).await);

    assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
    assert_eq!(next_change(&mut b).await.0, stats);
    assert!(card.watched(&sub).await);
}
