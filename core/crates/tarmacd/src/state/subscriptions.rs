use tarmac_protocol::{EventKind, Msg};

use crate::events::{Filter, Subscription};

use super::{Daemon, Known};

impl Daemon {
    /// The receiver comes first: a report is changed, and an exit recorded,
    /// before it is published, so each is in the snapshot, or after it in `rx`,
    /// or both. `terms`, `exits` and `reports` are each taken alone.
    pub(crate) async fn subscribe(
        &self,
        kinds: Option<Vec<String>>,
        term_id: Option<String>,
    ) -> Result<Subscription, String> {
        let filter = Filter::new(kinds, term_id.clone())?;
        let rx = self.events.subscribe();
        let mut snapshot = Vec::new();
        if let Some(id) = term_id {
            let exited = match self.knows_term(&id).await {
                None => return Err(format!("unknown terminal: {id}")),
                Some(Known::Live) => None,
                Some(Known::Exited(code)) => Some(code),
            };
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
