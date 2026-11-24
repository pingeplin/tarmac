//! The one task that writes to the app's socket, fed by the app channel.

use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};
use tokio::io::AsyncWrite;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// How long one frame may take to reach an app that reads.
pub(crate) const APP_WRITE_LIMIT: Duration = Duration::from_secs(10);

/// Writes each frame of `rx` until the session is cancelled, a write fails, or
/// one frame takes longer than `limit`. An app that stops reading but keeps
/// its socket open would otherwise fill the channel, and every sender would
/// wait on it, some with a lock held (#524). Ending drops `rx`, so a waiting
/// send returns, and cancels the session, so the app reconnects.
pub(crate) async fn write_frames(
    mut wr: impl AsyncWrite + Unpin,
    mut rx: mpsc::Receiver<Msg>,
    cancel: CancellationToken,
    limit: Duration,
) {
    loop {
        let msg = tokio::select! {
            () = cancel.cancelled() => break,
            msg = rx.recv() => match msg {
                Some(msg) => msg,
                None => break,
            },
        };
        let Ok(payload) = proto::encode(&msg) else { continue };
        let written = tokio::select! {
            () = cancel.cancelled() => break,
            written = tokio::time::timeout(limit, frame::write_async(&mut wr, &payload)) => written,
        };
        if !matches!(written, Ok(Ok(()))) {
            break;
        }
    }
    cancel.cancel();
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::DuplexStream;

    const LIMIT: Duration = Duration::from_millis(200);
    const MARGIN: Duration = Duration::from_millis(500);

    fn frame_of(n: usize) -> Msg {
        Msg::Err { msg: format!("frame {n} {}", "x".repeat(64)) }
    }

    /// A writer on a 1-slot channel, its peer, and a send that waits: one
    /// frame is in the write, one in the slot.
    async fn writer_with_a_waiting_send(
        limit: Duration,
    ) -> (DuplexStream, CancellationToken, tokio::task::JoinHandle<Result<(), mpsc::error::SendError<Msg>>>) {
        let (client, server) = tokio::io::duplex(8);
        let (tx, rx) = mpsc::channel(1);
        let cancel = CancellationToken::new();
        tokio::spawn(write_frames(server, rx, cancel.clone(), limit));
        tx.send(frame_of(1)).await.unwrap();
        tx.send(frame_of(2)).await.unwrap();
        let waiting = tokio::spawn(async move { tx.send(frame_of(3)).await });
        (client, cancel, waiting)
    }

    #[tokio::test]
    async fn a_peer_that_reads_nothing_ends_the_writer_after_the_limit() {
        let (_client, cancel, waiting) = writer_with_a_waiting_send(LIMIT).await;

        let sent = tokio::time::timeout(LIMIT + MARGIN, waiting).await.expect("the send returns after the limit");

        assert!(sent.unwrap().is_err());
        assert!(cancel.is_cancelled());
    }

    #[tokio::test]
    async fn a_cancel_while_the_writer_waits_on_a_write_ends_it() {
        let (_client, cancel, waiting) = writer_with_a_waiting_send(Duration::from_secs(30)).await;

        cancel.cancel();
        let sent = tokio::time::timeout(MARGIN, waiting).await.expect("the send returns on cancel");

        assert!(sent.unwrap().is_err());
    }

    #[tokio::test]
    async fn a_cancel_while_the_writer_waits_for_a_frame_ends_it() {
        let (_client, server) = tokio::io::duplex(8);
        let (tx, rx) = mpsc::channel(1);
        let cancel = CancellationToken::new();
        let writer = tokio::spawn(write_frames(server, rx, cancel.clone(), Duration::from_secs(30)));

        cancel.cancel();

        tokio::time::timeout(MARGIN, writer).await.expect("the writer ends on cancel").unwrap();
        assert!(tx.send(frame_of(1)).await.is_err());
    }

    #[tokio::test]
    async fn a_peer_that_closes_ends_the_writer_and_cancels_the_session() {
        let (client, server) = tokio::io::duplex(8);
        let (tx, rx) = mpsc::channel(1);
        let cancel = CancellationToken::new();
        let writer = tokio::spawn(write_frames(server, rx, cancel.clone(), Duration::from_secs(30)));
        drop(client);

        tx.send(frame_of(1)).await.unwrap();

        tokio::time::timeout(MARGIN, writer).await.expect("the writer ends on a failed write").unwrap();
        assert!(cancel.is_cancelled());
    }

    /// The limit is for one frame, not for the session: four frames, each read
    /// well inside the limit, take longer than the limit in total.
    #[tokio::test]
    async fn a_peer_slower_than_the_limit_in_total_but_not_per_frame_gets_every_frame() {
        const PER_FRAME_LIMIT: Duration = Duration::from_secs(1);
        let (mut client, server) = tokio::io::duplex(8);
        let (tx, rx) = mpsc::channel(4);
        let cancel = CancellationToken::new();
        tokio::spawn(write_frames(server, rx, cancel.clone(), PER_FRAME_LIMIT));
        for n in 1..=4 {
            tx.send(frame_of(n)).await.unwrap();
        }

        let mut got = Vec::new();
        for _ in 1..=4 {
            tokio::time::sleep(Duration::from_millis(400)).await;
            got.push(proto::decode(&frame::read_async(&mut client).await.unwrap()).unwrap());
        }

        assert_eq!(got, (1..=4).map(frame_of).collect::<Vec<_>>());
        assert!(!cancel.is_cancelled());
    }
}
