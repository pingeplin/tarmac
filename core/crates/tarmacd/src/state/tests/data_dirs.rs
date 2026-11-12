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
    fs: Arc<StuckFs>,
    _release: std::sync::mpsc::Sender<()>,
}

impl Card {
    /// `tmp` is canonical (`canon_tmp`).
    async fn on(tmp: PathBuf, source: Box<dyn WakeSource>) -> Self {
        let dir = tmp.join("d");
        let dash = write_doc(dir.join("dash.html"));
        let (fs, release) = stuck_fs();
        let daemon = held(&tmp, source, fs.clone()).await;
        let mut app = connect_app(&daemon).await;
        open_doc(&daemon, None, &dash).await;
        flushed(&mut app, &dash).await;
        Card { tmp, dir, dash, daemon, app, fs, _release: release }
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
    for _ in 0..2 {
        assert!(name(&card.daemon, &card.dash, Some(&stats)).await);
        assert_eq!(next_change(&mut card.app).await.0, stats);
    }
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
