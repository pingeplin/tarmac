use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};
use tarmac_protocol::Msg;
use tokio::sync::{Mutex, mpsc};
use tokio_util::sync::CancellationToken;

pub struct DocInfo {
    pub via: String,
    pub last_changed_ms: Option<u64>,
}

pub struct AppSlot {
    pub generation: u64,
    pub tx: mpsc::Sender<Msg>,
    pub cancel: CancellationToken,
}

pub struct WatcherState {
    debouncer: Debouncer<RecommendedWatcher, RecommendedCache>,
    watched_dirs: HashSet<PathBuf>,
}

pub struct Daemon {
    pub app: Mutex<Option<AppSlot>>,
    pub docs: Mutex<HashMap<PathBuf, DocInfo>>,
    pub terms: Mutex<HashMap<String, Arc<crate::term::TermHandle>>>,
    watcher: std::sync::Mutex<WatcherState>,
    next_generation: AtomicU64,
}

impl Daemon {
    pub fn new() -> anyhow::Result<Arc<Self>> {
        let (tx, rx) = mpsc::unbounded_channel::<DebounceEventResult>();
        // 100 ms debounce per docs/protocol.md file-watching semantics.
        let debouncer = new_debouncer(Duration::from_millis(100), None, move |res| {
            let _ = tx.send(res);
        })?;
        let daemon = Arc::new(Daemon {
            app: Mutex::new(None),
            docs: Mutex::new(HashMap::new()),
            terms: Mutex::new(HashMap::new()),
            watcher: std::sync::Mutex::new(WatcherState {
                debouncer,
                watched_dirs: HashSet::new(),
            }),
            next_generation: AtomicU64::new(1),
        });
        tokio::spawn(crate::docs::watch_loop(daemon.clone(), rx));
        Ok(daemon)
    }

    pub fn ensure_watched(&self, dir: &Path) -> anyhow::Result<()> {
        let mut w = self.watcher.lock().expect("watcher lock");
        if w.watched_dirs.contains(dir) {
            return Ok(());
        }
        w.debouncer.watch(dir, RecursiveMode::NonRecursive)?;
        w.watched_dirs.insert(dir.to_owned());
        Ok(())
    }

    pub async fn install_app(&self, tx: mpsc::Sender<Msg>) -> (u64, CancellationToken) {
        let cancel = CancellationToken::new();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let old = self.app.lock().await.replace(AppSlot {
            generation,
            tx,
            cancel: cancel.clone(),
        });
        if let Some(old) = old {
            tracing::info!("replacing previous app connection");
            old.cancel.cancel();
        }
        (generation, cancel)
    }

    pub async fn remove_app(&self, generation: u64) {
        let mut slot = self.app.lock().await;
        if slot.as_ref().is_some_and(|s| s.generation == generation) {
            *slot = None;
        }
    }

    // Push to the connected app, if any; otherwise drop silently.
    pub async fn push(&self, msg: Msg) {
        let tx = self.app.lock().await.as_ref().map(|s| s.tx.clone());
        if let Some(tx) = tx {
            let _ = tx.send(msg).await;
        }
    }
}
