use tarmac_protocol::{EventKind, Msg};

use crate::events::{Filter, Subscription};

use super::Daemon;

impl Daemon {
    /// The receiver comes first: a report is changed, and an exit recorded,
    /// before it is published, so each is in the snapshot, or after it in `rx`,
    /// or both. `terms`, `exits` and `reports` are each taken alone.
    pub async fn subscribe(&self, kinds: Option<Vec<String>>, term_id: Option<String>) -> Result<Subscription, String> {
        let filter = Filter::new(kinds, term_id.clone())?;
        let rx = self.events.subscribe();
        let mut snapshot = Vec::new();
        if let Some(id) = term_id {
            let live = self.term(&id).await.is_some();
            let exited = if live { None } else { self.exits.lock().expect("exits lock").lookup(&id) };
            if !live && exited.is_none() {
                return Err(format!("unknown terminal: {id}"));
            }
            if filter.wants(EventKind::Report) {
                snapshot.extend(self.reports.lock().await.snapshot(std::slice::from_ref(&id)));
            }
            if let Some(code) = exited.filter(|_| filter.wants(EventKind::Exit)) {
                snapshot.push(Msg::Exit { term_id: id, code, board_id: None });
            }
        }
        Ok(Subscription { rx, filter, snapshot })
    }
}
