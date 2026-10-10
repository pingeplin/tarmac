//! The pure board model: boards, their registries and the frames built from
//! them. No I/O, no locks — `Daemon` holds a `Boards` behind one mutex.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use tarmac_protocol::{BoardMeta, BoardViewport, DocEntry, Msg, Tile};

pub struct DocInfo {
    pub via: String,
    pub read: bool,
    pub repo: Option<String>,
    pub repo_root: Option<String>,
    pub repo_color: Option<u8>,
    pub last_changed_ms: Option<u64>,
    pub last_opened_ms: u64,
    /// The term that opened this doc; `None` when opened without a `TARMAC_TERM_ID`.
    pub term_id: Option<String>,
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

    pub fn contains(&self, id: &str) -> bool {
        self.index_of(id).is_some()
    }

    /// Whether any board has a doc directly in `dir`. The watch set is shared by
    /// every board, so one board's registry cannot answer this.
    pub fn dir_in_use(&self, dir: &Path) -> bool {
        self.boards.iter().any(|b| b.registry.docs.keys().any(|p| p.parent() == Some(dir)))
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

    /// Refused (false) for the last board or an unknown id. Deleting the active
    /// board activates the board now at its index (clamped to the new last).
    pub fn delete(&mut self, id: &str) -> bool {
        if self.boards.len() <= 1 {
            return false;
        }
        let Some(idx) = self.index_of(id) else {
            return false;
        };
        let was_active = self.active == id;
        self.boards.remove(idx);
        if was_active {
            let new_idx = idx.min(self.boards.len() - 1);
            self.active = self.boards[new_idx].id.clone();
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(!boards.delete("board-0"), "the last board can't be deleted");
        assert_eq!(boards.iter().count(), 1, "board-0 is still present");
        assert_eq!(boards.active_id(), "board-0");
    }

    #[test]
    fn delete_non_active_keeps_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, now active
        boards.set_active("board-0");
        assert!(boards.delete("board-1"));
        let ids: Vec<&str> = boards.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["board-0"]);
        assert_eq!(boards.active_id(), "board-0", "active is untouched by a non-active delete");
    }

    #[test]
    fn delete_active_board_fixes_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, active
        assert_eq!(boards.active_id(), "board-1");
        assert!(boards.delete("board-1"));
        // active falls back to the board now at the deleted index (board-0).
        assert_eq!(boards.active_id(), "board-0");
        assert_eq!(boards.iter().count(), 1);
    }

    #[test]
    fn delete_unknown_id_is_noop() {
        let mut boards = Boards::single();
        boards.create(); // board-1
        assert!(!boards.delete("board-404"));
        assert_eq!(boards.iter().count(), 2);
    }

    fn doc_info() -> DocInfo {
        DocInfo { via: "t".into(), read: false, repo: None, repo_root: None, repo_color: None, last_changed_ms: None, last_opened_ms: 0, term_id: None }
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

    #[test]
    fn dir_in_use_sees_a_doc_on_any_board() {
        let mut boards = Boards::single();
        let other = boards.create();
        boards.registry_mut(Some(DEFAULT_BOARD_ID)).docs.insert(PathBuf::from("/tmp/d/a.md"), doc_info());
        assert_eq!(boards.active_id(), other);

        assert!(boards.dir_in_use(Path::new("/tmp/d")));
        assert!(!boards.dir_in_use(Path::new("/tmp")), "a doc in a subdirectory does not count");
        assert!(!boards.dir_in_use(Path::new("/tmp/e")));
    }
}
