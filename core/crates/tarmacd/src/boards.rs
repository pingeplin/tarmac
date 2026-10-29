//! The pure board model: boards, their registries and the frames built from
//! them. No I/O, no locks — `Daemon` holds a `Boards` behind one mutex.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use tarmac_protocol::{BoardMeta, BoardViewport, DocEntry, Msg, Tile};

pub struct DocInfo {
    pub via: String,
    pub read: bool,
    pub repo: Option<String>,
    pub repo_root: Option<String>,
    pub repo_color: Option<u8>,
    pub last_changed_ms: Option<u64>,
    /// The file as the daemon last saw it for this board; `None` when there
    /// was no file to read. In memory only. A change is a file that differs
    /// from this (`Registry::take_changes`).
    pub seen: Option<FileStamp>,
    /// The `file_event` of the last change reached no app: none was connected,
    /// or it went away. In memory only. The next look tells it
    /// (`Registry::take_untold`).
    pub untold: bool,
    /// Restored, and its file not read yet. In memory only. Its first reading
    /// is taken as it is, with no change (`Registry::take_first_reading`), as a
    /// restart takes each file.
    pub unread: bool,
    pub last_opened_ms: u64,
    /// The term that opened this doc; `None` when opened without a `TARMAC_TERM_ID`.
    pub term_id: Option<String>,
}

/// What the daemon reads of a doc's file to know that it changed. The length
/// and the inode are there for a change that keeps the mtime: a writer that
/// puts the mtime back, two writes in one tick of a coarse clock, a save that
/// replaces the file by one of the same length.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct FileStamp {
    pub mtime: SystemTime,
    pub len: u64,
    pub inode: u64,
}

impl DocInfo {
    /// Takes the file as it is: what was seen, the time of its change, and
    /// nothing left to tell. Returns that time in ms.
    fn see(&mut self, stamp: FileStamp) -> u64 {
        self.seen = Some(stamp);
        self.untold = false;
        self.unread = false;
        let ms = epoch_ms(stamp.mtime);
        self.last_changed_ms = Some(ms);
        ms
    }

    /// Takes the first reading of an unread doc, with no change. False for a
    /// doc that is not unread.
    fn take_first_reading(&mut self, stamp: Option<FileStamp>) -> bool {
        if !std::mem::take(&mut self.unread) {
            return false;
        }
        self.seen = stamp;
        true
    }
}

pub fn epoch_ms(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub fn term_tile() -> Tile {
    Tile { kind: "term".into(), ..Default::default() }
}

pub struct Registry {
    pub docs: HashMap<PathBuf, DocInfo>,
    /// A new doc appends and a re-open never moves one; a layout snapshot reorders.
    pub dock: Vec<PathBuf>,
    pub tiles: Vec<Tile>,
    /// `None` until the app sends one in a layout snapshot.
    pub board: Option<BoardViewport>,
}

impl Registry {
    pub fn empty() -> Self {
        Registry { docs: HashMap::new(), dock: Vec::new(), tiles: vec![term_tile()], board: None }
    }

    pub fn entry(&self, path: &Path) -> Option<DocEntry> {
        let info = self.docs.get(path)?;
        Some(DocEntry {
            path: path.to_string_lossy().into_owned(),
            via: info.via.clone(),
            repo: info.repo.clone(),
            repo_root: info.repo_root.clone(),
            repo_color: info.repo_color,
            read: info.read,
            last_changed_ms: info.last_changed_ms,
            last_opened_ms: Some(info.last_opened_ms),
            term_id: info.term_id.clone(),
        })
    }

    pub fn dock_entries(&self) -> Vec<DocEntry> {
        self.dock.iter().filter_map(|p| self.entry(p)).collect()
    }

    /// Marks a known doc read; false when the path is unknown.
    pub fn mark_read(&mut self, path: &Path) -> bool {
        self.docs.get_mut(path).map(|info| info.read = true).is_some()
    }

    /// Merge per docs/protocol.md "layout": paths not in the registry are
    /// dropped; registered docs missing from the snapshot keep their previous
    /// relative order, appended at the end. The board viewport is last-writer-wins:
    /// a snapshot omitting it leaves the stored one untouched.
    pub fn apply_layout(&mut self, dock: Vec<String>, tiles: Vec<Tile>, board: Option<BoardViewport>) {
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut order: Vec<PathBuf> = Vec::new();
        for p in dock {
            let p = PathBuf::from(p);
            if self.docs.contains_key(&p) && seen.insert(p.clone()) {
                order.push(p);
            }
        }
        for p in std::mem::take(&mut self.dock) {
            if seen.insert(p.clone()) {
                order.push(p);
            }
        }
        self.dock = order;
        self.set_tiles(tiles);
        if board.is_some() {
            self.board = board;
        }
    }

    /// Takes `now` as each file at this moment and returns the docs whose file
    /// differs from what was seen, with the file's mtime in ms. "Differs", not
    /// "is newer": a file put back from a backup is a change, and one with an
    /// mtime in the future is not. A file that is gone is taken and not
    /// returned, so it is a change when it is back. The first reading of an
    /// unread doc is taken and not returned.
    pub fn take_changes(&mut self, now: &HashMap<PathBuf, Option<FileStamp>>) -> Vec<(PathBuf, u64)> {
        let mut changes = Vec::new();
        for (path, stamp) in now {
            let Some(info) = self.docs.get_mut(path) else { continue };
            if info.take_first_reading(*stamp) || info.seen == *stamp {
                continue;
            }
            match stamp {
                Some(stamp) => changes.push((path.clone(), info.see(*stamp))),
                // A file that is gone is not told, also when its last change
                // was held.
                None => {
                    info.seen = None;
                    info.untold = false;
                }
            }
        }
        changes
    }

    /// The first reading of each unread doc in `now`, with no change.
    pub fn take_first_readings(&mut self, now: &HashMap<PathBuf, Option<FileStamp>>) {
        for (path, stamp) in now {
            if let Some(info) = self.docs.get_mut(path) {
                info.take_first_reading(*stamp);
            }
        }
    }

    /// `doc_refresh`: takes the file as seen whether or not it differs, and
    /// returns its mtime in ms. `None`, with nothing taken, for an unknown
    /// path or no file: a file that is gone emits nothing until it is back.
    pub fn refresh(&mut self, path: &Path, stamp: Option<FileStamp>) -> Option<u64> {
        Some(self.docs.get_mut(path)?.see(stamp?))
    }

    /// The `file_event` for `path` reached no app.
    fn hold(&mut self, path: &Path) {
        if let Some(info) = self.docs.get_mut(path) {
            info.untold = true;
        }
    }

    /// The docs whose last change reached no app, with its time. They count as
    /// told from here on; the caller holds one again when it cannot send it.
    pub fn take_untold(&mut self) -> Vec<(PathBuf, u64)> {
        let mut untold = Vec::new();
        for (path, info) in &mut self.docs {
            if let (true, Some(ms)) = (std::mem::take(&mut info.untold), info.last_changed_ms) {
                untold.push((path.clone(), ms));
            }
        }
        untold
    }

    /// False when the path is unknown.
    pub fn close_doc(&mut self, path: &Path) -> bool {
        let existed = self.docs.remove(path).is_some();
        if existed {
            self.dock.retain(|p| p != path);
        }
        existed
    }

    pub fn set_tiles(&mut self, tiles: Vec<Tile>) {
        let mut kept: Vec<Tile> = Vec::new();
        // Each terminal tile keeps a distinct term_id so N terminal cards persist
        // distinct positions; a `None` term_id is the legacy single-terminal slot,
        // kept once. Duplicate ids are dropped.
        let mut seen_terms: HashSet<Option<String>> = HashSet::new();
        for t in tiles {
            match t.kind.as_str() {
                "term" => {
                    if seen_terms.insert(t.term_id.clone()) {
                        kept.push(t);
                    }
                }
                "doc" => {
                    if t.path.as_deref().is_some_and(|p| self.docs.contains_key(Path::new(p))) {
                        kept.push(t);
                    }
                }
                // A kind from a newer protocol: skip the tile, keep the rest.
                _ => {}
            }
        }
        // A term-less layout gets the default terminal so a board is never term-less.
        if seen_terms.is_empty() {
            kept.insert(0, term_tile());
        }
        self.tiles = kept;
    }
}

pub type BoardId = String;
pub const DEFAULT_BOARD_ID: &str = "board-0";

pub struct Board {
    pub id: BoardId,
    /// User-given display name; the switcher falls back to the id.
    pub name: Option<String>,
    pub registry: Registry,
}

impl Board {
    pub fn new(id: impl Into<BoardId>, registry: Registry) -> Self {
        Board { id: id.into(), name: None, registry }
    }
}

/// The boards in display order plus the active one — never empty, and `active`
/// always names a live board.
pub struct Boards {
    boards: Vec<Board>,
    active: BoardId,
}

impl Boards {
    pub fn single() -> Self {
        Boards { boards: vec![Board::new(DEFAULT_BOARD_ID, Registry::empty())], active: DEFAULT_BOARD_ID.into() }
    }

    /// An `active` that names no board falls back to the first board.
    pub fn from_boards(boards: Vec<Board>, active: BoardId) -> Self {
        if boards.is_empty() {
            return Boards::single();
        }
        let active = if boards.iter().any(|b| b.id == active) {
            active
        } else {
            boards[0].id.clone()
        };
        Boards { boards, active }
    }

    fn index_of(&self, id: &str) -> Option<usize> {
        self.boards.iter().position(|b| b.id == id)
    }

    pub fn active_id(&self) -> &str {
        &self.active
    }

    fn active_board(&self) -> &Board {
        &self.boards[self.index_of(&self.active).expect("active board present")]
    }

    pub fn active_registry(&self) -> &Registry {
        &self.active_board().registry
    }

    pub fn active_registry_mut(&mut self) -> &mut Registry {
        self.registry_mut(None)
    }

    /// The registry of board `id`; `None` or an unknown id falls back to the active board.
    pub fn registry_mut(&mut self, id: Option<&str>) -> &mut Registry {
        let idx = id
            .and_then(|id| self.index_of(id))
            .or_else(|| self.index_of(&self.active))
            .expect("active board present");
        &mut self.boards[idx].registry
    }

    pub fn iter(&self) -> impl Iterator<Item = &Board> {
        self.boards.iter()
    }

    pub fn registries_mut(&mut self) -> impl Iterator<Item = &mut Registry> {
        self.boards.iter_mut().map(|b| &mut b.registry)
    }

    /// Holds the doc of board `id` (`Registry::hold`). Nothing for a board that
    /// is gone: the change was that board's, and not the active board's.
    pub fn hold(&mut self, id: &str, path: &Path) {
        if let Some(idx) = self.index_of(id) {
            self.boards[idx].registry.hold(path);
        }
    }

    /// The path of each unread doc, of every board.
    pub fn unread_doc_paths(&self) -> impl Iterator<Item = &PathBuf> {
        self.boards.iter().flat_map(|b| b.registry.docs.iter().filter(|(_, info)| info.unread).map(|(path, _)| path))
    }

    /// The path of each registered doc, of every board.
    pub fn doc_paths(&self) -> HashSet<PathBuf> {
        self.boards.iter().flat_map(|b| b.registry.docs.keys().cloned()).collect()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.index_of(id).is_some()
    }

    /// Each board's identity plus its live-pty count, taken from `live` (the
    /// terms live on `Daemon`, not here); a board missing from the map has none.
    pub fn board_list_msg(&self, live: &HashMap<BoardId, Vec<String>>) -> Msg {
        Msg::BoardList {
            boards: self
                .boards
                .iter()
                .map(|b| BoardMeta {
                    board_id: b.id.clone(),
                    name: b.name.clone(),
                    running: Some(live.get(&b.id).map_or(0, |terms| terms.len() as u32)),
                })
                .collect(),
            active: self.active.clone(),
        }
    }

    /// The active board's restore, stamped with its id so the app binds it
    /// unambiguously across rapid switches, and with the daemon-owned shells the
    /// app re-binds to instead of cold-spawning.
    pub fn active_restore_msg(&self, live_terms: Vec<String>) -> Msg {
        let board = self.active_board();
        Msg::Restore {
            docs: board.registry.dock_entries(),
            tiles: board.registry.tiles.clone(),
            board: board.registry.board.clone(),
            board_id: Some(board.id.clone()),
            live_terms,
        }
    }

    /// False (no-op) if no such board.
    pub fn set_active(&mut self, id: &str) -> bool {
        if self.contains(id) {
            self.active = id.to_string();
            true
        } else {
            false
        }
    }

    /// Mint `board-N` (N one past the max existing index), make it active and
    /// return its id.
    pub fn create(&mut self) -> BoardId {
        let next = self
            .boards
            .iter()
            .filter_map(|b| b.id.strip_prefix("board-").and_then(|s| s.parse::<usize>().ok()))
            .max()
            .map(|m| m + 1)
            .unwrap_or(self.boards.len());
        let id = format!("board-{next}");
        self.boards.push(Board::new(id.clone(), Registry::empty()));
        self.active = id.clone();
        id
    }

    /// `None` clears the name back to the id fallback. False (no-op) if no such board.
    pub fn rename(&mut self, id: &str, name: Option<String>) -> bool {
        match self.boards.iter_mut().find(|b| b.id == id) {
            Some(b) => {
                b.name = name;
                true
            }
            None => false,
        }
    }

    /// Returns the removed board. Refused (`None`) for the last board or an
    /// unknown id. Deleting the active board activates the board now at its
    /// index (clamped to the new last).
    pub fn delete(&mut self, id: &str) -> Option<Board> {
        if self.boards.len() <= 1 {
            return None;
        }
        let idx = self.index_of(id)?;
        let was_active = self.active == id;
        let board = self.boards.remove(idx);
        if was_active {
            let new_idx = idx.min(self.boards.len() - 1);
            self.active = self.boards[new_idx].id.clone();
        }
        Some(board)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn term(id: Option<&str>) -> Tile {
        Tile { kind: "term".into(), term_id: id.map(str::to_string), ..term_tile() }
    }

    fn terms_kept(r: &Registry) -> Vec<Option<String>> {
        r.tiles.iter().filter(|t| t.kind == "term").map(|t| t.term_id.clone()).collect()
    }

    #[test]
    fn set_tiles_keeps_distinct_term_ids() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(Some("t1")), term(Some("t2"))]);
        assert_eq!(terms_kept(&r), vec![Some("t1".into()), Some("t2".into())]);
    }

    #[test]
    fn set_tiles_drops_duplicate_term_id() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(Some("t1")), term(Some("t1"))]);
        assert_eq!(terms_kept(&r), vec![Some("t1".into())]);
    }

    // A legacy single-terminal layout (term tile, no term_id) keeps exactly one
    // None-keyed slot.
    #[test]
    fn set_tiles_keeps_one_legacy_none_term() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(None), term(None)]);
        assert_eq!(terms_kept(&r), vec![None]);
    }

    #[test]
    fn set_tiles_empty_inserts_default_terminal() {
        let mut r = Registry::empty();
        r.set_tiles(vec![]);
        assert_eq!(r.tiles, vec![term_tile()]);
    }

    #[test]
    fn layout_without_a_viewport_keeps_the_stored_one() {
        let mut r = Registry::empty();
        let viewport = BoardViewport { zoom: 1.5, cx: 120.0, cy: -40.0 };
        r.apply_layout(vec![], vec![term_tile()], Some(viewport.clone()));
        r.apply_layout(vec![], vec![term_tile()], None);
        assert_eq!(r.board, Some(viewport));
    }

    fn name_of<'a>(boards: &'a Boards, id: &str) -> Option<&'a str> {
        boards.iter().find(|b| b.id == id).and_then(|b| b.name.as_deref())
    }

    #[test]
    fn rename_sets_and_clears_name() {
        let mut boards = Boards::single();
        assert!(boards.rename("board-0", Some("infra".into())));
        assert_eq!(name_of(&boards, "board-0"), Some("infra"));
        assert!(boards.rename("board-0", None));
        assert_eq!(name_of(&boards, "board-0"), None);
        assert!(!boards.rename("board-404", Some("x".into())));
    }

    #[test]
    fn delete_refuses_last_board() {
        let mut boards = Boards::single();
        assert!(boards.delete("board-0").is_none(), "the last board can't be deleted");
        assert_eq!(boards.iter().count(), 1, "board-0 is still present");
        assert_eq!(boards.active_id(), "board-0");
    }

    #[test]
    fn delete_non_active_keeps_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, now active
        boards.set_active("board-0");
        assert!(boards.delete("board-1").is_some());
        let ids: Vec<&str> = boards.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["board-0"]);
        assert_eq!(boards.active_id(), "board-0", "active is untouched by a non-active delete");
    }

    #[test]
    fn delete_active_board_fixes_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, active
        assert_eq!(boards.active_id(), "board-1");
        assert!(boards.delete("board-1").is_some());
        // active falls back to the board now at the deleted index (board-0).
        assert_eq!(boards.active_id(), "board-0");
        assert_eq!(boards.iter().count(), 1);
    }

    #[test]
    fn delete_unknown_id_is_noop() {
        let mut boards = Boards::single();
        boards.create(); // board-1
        assert!(boards.delete("board-404").is_none());
        assert_eq!(boards.iter().count(), 2);
    }

    fn doc_info() -> DocInfo {
        DocInfo { via: "t".into(), read: false, repo: None, repo_root: None, repo_color: None, last_changed_ms: None, seen: None, untold: false, unread: false, last_opened_ms: 0, term_id: None }
    }

    #[test]
    fn doc_close_prunes_closed_path_from_dock() {
        let mut reg = Registry::empty();
        let doc = PathBuf::from("/tmp/s6/a.md");
        reg.docs.insert(doc.clone(), doc_info());
        reg.dock.push(doc.clone());
        assert!(reg.dock.contains(&doc));
        assert!(reg.close_doc(&doc));
        assert!(!reg.dock.contains(&doc));
    }

    fn stamp(secs: u64, len: u64, inode: u64) -> Option<FileStamp> {
        Some(FileStamp { mtime: UNIX_EPOCH + Duration::from_secs(secs), len, inode })
    }

    fn at(secs: u64) -> Option<FileStamp> {
        stamp(secs, 4, 1)
    }

    fn registry_that_saw(path: &Path, seen: Option<FileStamp>) -> Registry {
        let mut reg = Registry::empty();
        reg.docs.insert(path.to_owned(), DocInfo { seen, ..doc_info() });
        reg
    }

    fn now(path: &Path, stamp: Option<FileStamp>) -> HashMap<PathBuf, Option<FileStamp>> {
        HashMap::from([(path.to_owned(), stamp)])
    }

    // A writer that puts the mtime back, two writes in one tick of a coarse
    // clock, a save that replaces the file: the length or the inode still tells.
    #[test]
    fn a_file_with_the_same_mtime_and_another_length_or_inode_is_a_change() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, stamp(10, 4, 1));

        assert_eq!(reg.take_changes(&now(&doc, stamp(10, 9, 1))), vec![(doc.clone(), 10_000)], "another length");
        assert_eq!(reg.take_changes(&now(&doc, stamp(10, 9, 2))), vec![(doc.clone(), 10_000)], "another inode");
        assert_eq!(reg.take_changes(&now(&doc, stamp(10, 9, 2))), vec![]);
    }

    #[test]
    fn a_change_that_reached_no_app_is_told_one_time_later() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));
        assert_eq!(reg.take_untold(), vec![], "nothing is held at the start");

        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc.clone(), 20_000)]);
        reg.hold(&doc);
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![], "the file is as it was seen");
        assert_eq!(reg.take_untold(), vec![(doc.clone(), 20_000)]);
        assert_eq!(reg.take_untold(), vec![]);
    }

    // A file that changed again is told by `take_changes`, with its new time.
    #[test]
    fn a_held_change_that_a_newer_one_follows_is_told_as_the_newer_one_only() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));
        reg.take_changes(&now(&doc, at(20)));
        reg.hold(&doc);

        assert_eq!(reg.take_changes(&now(&doc, at(30))), vec![(doc.clone(), 30_000)]);
        assert_eq!(reg.take_untold(), vec![]);
    }

    #[test]
    fn holding_a_doc_that_is_not_there_does_nothing() {
        let mut reg = Registry::empty();
        reg.hold(Path::new("/d/gone.md"));
        assert_eq!(reg.take_untold(), vec![]);
    }

    #[test]
    fn a_refresh_takes_the_file_as_seen_and_as_told() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));
        reg.take_changes(&now(&doc, at(20)));
        reg.hold(&doc);

        assert_eq!(reg.refresh(&doc, at(30)), Some(30_000));
        assert_eq!(reg.docs[&doc].last_changed_ms, Some(30_000));
        assert_eq!(reg.take_changes(&now(&doc, at(30))), vec![], "the file is as the refresh saw it");
        assert_eq!(reg.take_untold(), vec![], "the refresh told it");
        assert_eq!(reg.refresh(Path::new("/d/other.md"), at(30)), None);
    }

    // "If the file is deleted, stop emitting until the path exists again."
    #[test]
    fn a_held_change_of_a_file_that_is_gone_is_not_told() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));
        reg.take_changes(&now(&doc, at(20)));
        reg.hold(&doc);

        assert_eq!(reg.take_changes(&now(&doc, None)), vec![]);
        assert_eq!(reg.take_untold(), vec![]);
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc, 20_000)], "it is a change when it is back");
    }

    // A doc that was held before it had a change has no time to tell.
    #[test]
    fn a_held_doc_with_no_recorded_change_is_not_told() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));
        reg.hold(&doc);
        assert_eq!(reg.take_untold(), vec![]);
    }

    #[test]
    fn a_hold_is_for_the_board_that_is_named() {
        let doc = PathBuf::from("/d/a.md");
        let mut boards = Boards::single();
        let other = boards.create();
        for id in [DEFAULT_BOARD_ID, other.as_str()] {
            let info = DocInfo { last_changed_ms: Some(20_000), ..doc_info() };
            boards.registry_mut(Some(id)).docs.insert(doc.clone(), info);
        }

        boards.hold(DEFAULT_BOARD_ID, &doc);
        boards.hold("board-404", &doc);
        assert_eq!(boards.active_id(), other);
        assert_eq!(boards.active_registry_mut().take_untold(), vec![], "the active board is not the one named");
        assert_eq!(boards.registry_mut(Some(DEFAULT_BOARD_ID)).take_untold(), vec![(doc, 20_000)]);
    }

    #[test]
    fn a_file_that_differs_from_what_was_seen_is_a_change_one_time() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));

        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc.clone(), 20_000)]);
        assert_eq!(reg.docs[&doc].last_changed_ms, Some(20_000));
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![], "it was taken");
    }

    #[test]
    fn a_file_as_it_was_seen_is_no_change() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));

        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![]);
        assert_eq!(reg.docs[&doc].last_changed_ms, None);
    }

    // A restored backup has an older mtime. "Newer" would miss it.
    #[test]
    fn an_older_file_is_a_change_too() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));

        assert_eq!(reg.take_changes(&now(&doc, at(5))), vec![(doc, 5_000)]);
    }

    #[test]
    fn a_file_that_is_gone_is_no_change_until_it_is_back() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));

        assert_eq!(reg.take_changes(&now(&doc, None)), vec![]);
        assert_eq!(reg.docs[&doc].last_changed_ms, None);
        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![(doc, 10_000)], "also with its old mtime");
    }

    #[test]
    fn a_file_that_was_not_there_at_the_open_is_a_change_when_it_comes() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, None);

        assert_eq!(reg.take_changes(&now(&doc, None)), vec![]);
        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![(doc, 10_000)]);
    }

    fn unread_registry(path: &Path) -> Registry {
        let mut reg = Registry::empty();
        reg.docs.insert(path.to_owned(), DocInfo { unread: true, last_changed_ms: Some(5_000), ..doc_info() });
        reg
    }

    // 2610.0012 D10: a reading of a file and a reading of none end `unread`
    // alike, and so does a refresh.
    #[test]
    fn the_first_reading_of_an_unread_doc_is_no_change() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = unread_registry(&doc);
        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![]);
        assert_eq!(reg.docs[&doc].last_changed_ms, Some(5_000), "as restored");
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc.clone(), 20_000)]);

        let mut reg = unread_registry(&doc);
        assert_eq!(reg.take_changes(&now(&doc, None)), vec![]);
        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![(doc.clone(), 10_000)], "it was gone");

        let mut reg = unread_registry(&doc);
        assert_eq!(reg.refresh(&doc, at(10)), Some(10_000));
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc, 20_000)]);
    }

    // A refresh that finds no file pushes nothing and takes nothing: the doc
    // stays unread, and the first reading of a file is still no change.
    #[test]
    fn a_refresh_of_an_unread_doc_with_no_file_leaves_it_unread() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = unread_registry(&doc);
        assert_eq!(reg.refresh(&doc, None), None);
        assert_eq!(reg.take_changes(&now(&doc, at(10))), vec![]);
        assert_eq!(reg.docs[&doc].last_changed_ms, Some(5_000));
    }

    #[test]
    fn a_doc_that_was_not_looked_at_keeps_what_was_seen() {
        let doc = PathBuf::from("/d/a.md");
        let mut reg = registry_that_saw(&doc, at(10));

        assert_eq!(reg.take_changes(&now(Path::new("/d/other.md"), at(20))), vec![]);
        assert_eq!(reg.take_changes(&now(&doc, at(20))), vec![(doc, 20_000)]);
    }
}
