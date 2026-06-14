//! Durable daemon state (registry + dock order + tiles) as JSON on disk.
//! Contract per docs/protocol.md: a daemon restart followed by an app connect
//! must produce a restore indistinguishable from one without the restart.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tarmac_protocol::{BoardViewport, Tile};
use tracing::warn;

use crate::state::{Board, Boards, DEFAULT_BOARD_ID, Daemon, DocInfo, Registry};

const SAVE_DEBOUNCE: Duration = Duration::from_millis(150);

#[derive(Serialize, Deserialize)]
struct PersistedDoc {
    path: String,
    via: String,
    read: bool,
    last_changed_ms: Option<u64>,
    #[serde(default)]
    last_opened_ms: u64,
    // Written for inspectability but recomputed at load (crib §1.1: a .git
    // appearing or vanishing between runs is an observed fact).
    repo: Option<String>,
    repo_root: Option<String>,
    repo_color: Option<u8>,
    // v4 Phase 3: the term that opened the doc (provenance + gravity owner).
    // serde default => None for pre-Phase-3 state files.
    #[serde(default)]
    term_id: Option<String>,
}

// One persisted board: its id, optional display name, and the per-board
// registry state (docs in dock order, tiles with v4 geometry, board viewport).
#[derive(Serialize, Deserialize)]
struct PersistedBoard {
    board_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(default)]
    docs: Vec<PersistedDoc>,
    #[serde(default)]
    tiles: Vec<Tile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    board: Option<BoardViewport>,
}

// M3 nested shape: `boards[]` + the `active` board id. The pre-M3 flat fields
// (`docs`/`tiles`/`board` at top level) are read once for the board-0 migration
// and never written again (snapshot always emits `boards`), so a pre-M3 file
// upgrades losslessly to board-0 on first load.
#[derive(Serialize, Deserialize, Default)]
struct PersistedState {
    #[serde(default)]
    boards: Vec<PersistedBoard>,
    #[serde(default = "default_active")]
    active: String,
    // Legacy pre-M3 flat fields: migration input only, never serialized.
    #[serde(default, skip_serializing)]
    docs: Vec<PersistedDoc>,
    #[serde(default, skip_serializing)]
    tiles: Vec<Tile>,
    #[serde(default, skip_serializing)]
    board: Option<BoardViewport>,
}

fn default_active() -> String {
    DEFAULT_BOARD_ID.to_string()
}

// Missing or unreadable/corrupt state is never fatal: log and start empty.
pub fn load(path: &Path) -> Boards {
    let state = match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice::<PersistedState>(&bytes) {
            Ok(s) => s,
            Err(e) => {
                warn!("corrupt state file {} ({e}); starting empty", path.display());
                PersistedState::default()
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => PersistedState::default(),
        Err(e) => {
            warn!("cannot read state file {} ({e}); starting empty", path.display());
            PersistedState::default()
        }
    };
    let boards: Vec<Board> = if state.boards.is_empty() {
        // Pre-M3 flat file (or the empty default): migrate the legacy top-level
        // docs/tiles/board into board-0 verbatim — byte-for-byte the registry
        // the old flat `load` produced, so an upgrade is invisible.
        vec![hydrate(PersistedBoard {
            board_id: DEFAULT_BOARD_ID.to_string(),
            name: None,
            docs: state.docs,
            tiles: state.tiles,
            board: state.board,
        })]
    } else {
        state.boards.into_iter().map(hydrate).collect()
    };
    Boards::from_boards(boards, state.active)
}

// Rebuild one board's in-memory registry from its persisted form. Repo metadata
// is recomputed at load (crib §1.1: a .git appearing/vanishing between runs is
// an observed fact), exactly as the pre-M3 flat loader did.
fn hydrate(pb: PersistedBoard) -> Board {
    let mut reg = Registry::empty();
    for d in pb.docs {
        let path = PathBuf::from(&d.path);
        if reg.docs.contains_key(&path) {
            continue;
        }
        let repo = crate::docs::derive_repo(&path);
        reg.docs.insert(
            path.clone(),
            DocInfo {
                via: d.via,
                read: d.read,
                repo: repo.as_ref().map(|r| r.name.clone()),
                repo_root: repo.as_ref().map(|r| r.root.clone()),
                repo_color: repo.as_ref().map(|r| r.color),
                last_changed_ms: d.last_changed_ms,
                last_opened_ms: d.last_opened_ms,
                term_id: d.term_id,
            },
        );
        reg.dock.push(path);
    }
    reg.set_tiles(pb.tiles);
    reg.board = pb.board;
    Board { id: pb.board_id, name: pb.name, registry: reg }
}

fn persisted_doc(reg: &Registry, p: &Path) -> Option<PersistedDoc> {
    let info = reg.docs.get(p)?;
    Some(PersistedDoc {
        path: p.to_string_lossy().into_owned(),
        via: info.via.clone(),
        read: info.read,
        last_changed_ms: info.last_changed_ms,
        last_opened_ms: info.last_opened_ms,
        repo: info.repo.clone(),
        repo_root: info.repo_root.clone(),
        repo_color: info.repo_color,
        term_id: info.term_id.clone(),
    })
}

fn snapshot(boards: &Boards) -> PersistedState {
    PersistedState {
        boards: boards
            .iter()
            .map(|b| PersistedBoard {
                board_id: b.id.clone(),
                name: b.name.clone(),
                docs: b.registry.dock.iter().filter_map(|p| persisted_doc(&b.registry, p)).collect(),
                tiles: b.registry.tiles.clone(),
                board: b.registry.board.clone(),
            })
            .collect(),
        active: boards.active_id().to_string(),
        // Legacy flat fields are never written (skip_serializing).
        docs: Vec::new(),
        tiles: Vec::new(),
        board: None,
    }
}

fn write_atomic(path: &Path, state: &PersistedState) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("state path has no parent: {}", path.display()))?;
    std::fs::create_dir_all(parent)?;
    let tmp = path.with_extension("json.tmp");
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(&serde_json::to_vec_pretty(state)?)?;
    // fsync before rename so a crash never swaps in a truncated file.
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    // Per-test unique state path under the OS temp dir (no .git anywhere on the
    // walk, so derive_repo deterministically yields None for these fake paths).
    fn tmp_state(tag: &str) -> PathBuf {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("tarmac-persist-{}-{}-{n}", std::process::id(), tag));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("state.json")
    }

    // A realistic pre-M3 flat state file: top-level docs/tiles/board, no
    // `boards` key. (repo fields are written for inspectability but recomputed
    // at load — they are None here because the fake paths have no .git.)
    const LEGACY_FLAT: &str = r#"{
        "docs": [
            {"path":"/nx-tarmac/plan.md","via":"cli","read":false,"last_changed_ms":1718000000000,"last_opened_ms":1718000000001,"repo":"proj","repo_root":"/nx-tarmac","repo_color":2,"term_id":"t1"},
            {"path":"/nx-tarmac/notes.md","via":"user","read":true,"last_changed_ms":null,"last_opened_ms":1718000000002}
        ],
        "tiles": [
            {"kind":"term","x":80.0,"y":80.0,"w":470.0,"h":330.0,"z":0},
            {"kind":"doc","path":"/nx-tarmac/plan.md","x":648.0,"y":80.0,"w":392.0,"h":310.0,"z":1}
        ],
        "board": {"zoom":0.82,"cx":640.0,"cy":360.0}
    }"#;

    // The load-bearing P1 acceptance: a pre-M3 flat file migrates to exactly one
    // board-0 carrying the legacy docs/dock/tiles/viewport verbatim.
    #[test]
    fn legacy_flat_file_migrates_to_board_0() {
        let path = tmp_state("migrate");
        std::fs::write(&path, LEGACY_FLAT).unwrap();
        let boards = load(&path);

        assert_eq!(boards.iter().count(), 1, "one board after migration");
        assert_eq!(boards.active_id(), DEFAULT_BOARD_ID);
        let b = boards.iter().next().unwrap();
        assert_eq!(b.id, DEFAULT_BOARD_ID);
        assert_eq!(b.name, None);

        let reg = boards.active_registry();
        // Dock order preserved.
        assert_eq!(
            reg.dock,
            vec![PathBuf::from("/nx-tarmac/plan.md"), PathBuf::from("/nx-tarmac/notes.md")]
        );
        // read flags preserved; repo recomputed (None for a non-.git path).
        let plan = reg.docs.get(Path::new("/nx-tarmac/plan.md")).unwrap();
        assert!(!plan.read);
        assert_eq!(plan.repo, None, "repo is recomputed at load, not trusted from disk");
        assert_eq!(plan.last_changed_ms, Some(1718000000000));
        assert_eq!(plan.term_id.as_deref(), Some("t1"));
        assert!(reg.docs.get(Path::new("/nx-tarmac/notes.md")).unwrap().read);
        // Tile geometry + viewport preserved.
        assert_eq!(reg.tiles.len(), 2);
        assert_eq!(reg.tiles[0].kind, "term");
        assert_eq!(reg.tiles[0].x, Some(80.0));
        assert_eq!(reg.tiles[1].path.as_deref(), Some("/nx-tarmac/plan.md"));
        assert_eq!(reg.board, Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }));

        // The active board's restore frame stays the legacy shape: board_id None.
        match reg.restore_msg() {
            tarmac_protocol::Msg::Restore { board_id, docs, tiles, board } => {
                assert_eq!(board_id, None);
                assert_eq!(docs.len(), 2);
                assert_eq!(tiles.len(), 2);
                assert_eq!(board, Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }));
            }
            other => panic!("expected restore, got {other:?}"),
        }
    }

    // Writing is one-way: a snapshot emits only the nested shape (no top-level
    // docs/tiles/board), and load→snapshot→reload is idempotent.
    #[test]
    fn snapshot_writes_nested_shape_and_round_trips() {
        let path = tmp_state("nested");
        std::fs::write(&path, LEGACY_FLAT).unwrap();
        let boards = load(&path);

        let state = snapshot(&boards);
        let v = serde_json::to_value(&state).unwrap();
        assert!(v.get("boards").and_then(|b| b.as_array()).is_some_and(|a| a.len() == 1));
        assert_eq!(v["boards"][0]["board_id"], serde_json::json!(DEFAULT_BOARD_ID));
        assert_eq!(v["active"], serde_json::json!(DEFAULT_BOARD_ID));
        // Legacy flat keys are never written.
        assert!(v.get("docs").is_none(), "top-level docs must not be serialized");
        assert!(v.get("tiles").is_none(), "top-level tiles must not be serialized");
        assert!(v.get("board").is_none(), "top-level board must not be serialized");

        // Write the nested shape and reload: identical board-0 state.
        write_atomic(&path, &state).unwrap();
        let reloaded = load(&path);
        assert_eq!(reloaded.iter().count(), 1);
        assert_eq!(reloaded.active_registry().dock, boards.active_registry().dock);
        assert_eq!(reloaded.active_registry().tiles, boards.active_registry().tiles);
        assert_eq!(reloaded.active_registry().board, boards.active_registry().board);
    }

    // A nested multi-board file loads every board in order; an `active` naming a
    // missing board falls back to the first board.
    #[test]
    fn nested_multi_board_loads_in_order_with_active_fallback() {
        let path = tmp_state("multi");
        std::fs::write(
            &path,
            r#"{
                "boards": [
                    {"board_id":"board-0","tiles":[{"kind":"term"}]},
                    {"board_id":"board-1","name":"infra","tiles":[{"kind":"term"}]}
                ],
                "active": "board-9"
            }"#,
        )
        .unwrap();
        let boards = load(&path);
        let ids: Vec<&str> = boards.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["board-0", "board-1"]);
        assert_eq!(boards.iter().nth(1).unwrap().name.as_deref(), Some("infra"));
        // Unknown active id → first board.
        assert_eq!(boards.active_id(), "board-0");
    }

    // Missing or corrupt files are never fatal: a single default board-0.
    #[test]
    fn missing_and_corrupt_files_yield_default_board() {
        let missing = tmp_state("missing");
        let boards = load(&missing); // never written
        assert_eq!(boards.iter().count(), 1);
        assert_eq!(boards.active_id(), DEFAULT_BOARD_ID);
        // A default board is never term-less.
        assert_eq!(boards.active_registry().tiles.len(), 1);

        let corrupt = tmp_state("corrupt");
        std::fs::write(&corrupt, b"{ this is not json").unwrap();
        let boards = load(&corrupt);
        assert_eq!(boards.iter().count(), 1);
        assert_eq!(boards.active_id(), DEFAULT_BOARD_ID);
    }
}

// Dirty-flag + short sleep coalesces mutation bursts into one write.
pub async fn save_loop(daemon: Arc<Daemon>) {
    loop {
        daemon.dirty_notified().await;
        tokio::time::sleep(SAVE_DEBOUNCE).await;
        let state = {
            let boards = daemon.boards.lock().await;
            snapshot(&boards)
        };
        if let Err(e) = write_atomic(daemon.state_path(), &state) {
            warn!("state save failed: {e}");
        }
    }
}
