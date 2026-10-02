# Terminal scrollback across a webview reload — manual QA (spec 2609.0008, issue #41)

The four QA-only scenarios from `.blueprint/specs/2609.0008_reload_scrollback.md`.
S1, S2, S5–S10 and S13 are automated (`core/crates/tarmacd/tests/scrollback_integration.rs`,
`core/crates/tarmac-protocol/src/lib.rs` V12/V13, `desktop/src-tauri/src/bridge.rs`
unit tests). S3, S4, S11 and S12 need a real webview reload, which the React/Tauri
shell has no unit tests for by design.

**CAUTION:** the dev app must not be served by an installed `tarmacd`. Isolate by
socket (`TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock`, which `make run` sets) or use
`make kill-daemon` — never `pkill tarmacd`, which kills the operator's own Tarmac.

## Status: VERIFIED — 4/4 PASS (2026-09-07, commit `3ff175a`)

S3, S4, S11 and S12 were all run by the maintainer against the dev app built from
`3ff175a` — the branch tip, i.e. #41's fix plus the #123 reload re-sync it depends
on — and all four passed.

Two things a later reader should know about the strength of this record:

- **Judged by eye.** Each scenario was assessed from the screen as the steps below
  describe. No screenshots, byte counts, toast counts or terminal transcripts were
  captured, so nothing here is reproducible from the artifacts — unlike
  `doc-refresh-qa.md`, whose Observations name specific files and readings.
- **S3's negative half is the weakest claim.** "No repeated block and no interleaved
  garbage at the seam" was a visual judgement over `seq 1 500` output. The one-chunk
  duplicate/loss windows under Known limitations are far too small to show up that
  way, so this run does not rule them out; it rules out a *gross* seam defect.

The earlier attempt at S3 failed for a reason outside #41 and is now issue #123
(`Bridge::replay` re-emitting the connect-time restore, so ⌘T cards vanished on
reload). This run is the re-run after that fix landed as the branch's second commit.

## Steps

1. `make run`. Press ⌘T twice. In each terminal run `seq 1 500` and confirm the
   output scrolls.
2. Right-click empty board canvas → **Reload**.
   - [x] **S3** — both cards show the `seq` output after the remount; scrolling up
         reaches history (up to the daemon's 256 KiB cap); no repeated block and no
         interleaved garbage at the seam between history and live output.
3. Type `echo hi` + Return in a reloaded card.
   - [x] **S4** — characters echo as typed; `hi` prints.
4. In one card type `exit` + Return.
   - [x] **S11** — the card disappears (or is replaced by a fresh terminal when it
         was the board's last live one) — identical to `main`. The permanent-death
         path is untouched by this change.
5. `make kill-daemon`.
   - [x] **S12** — the "daemon restarted — terminals lost" toast appears exactly
         once; remaining terminal cards render dead; ⌘T still opens a new terminal.

## Known limitations (expected, not bugs)

- **A reload can still take two restores, in one narrow window.** If the daemon's
  connect-time restore reaches the frontend before `frontend_ready` reaches the
  bridge, the re-requested restore is that board's second and takes the
  reconnect-revive path (cards marked dead). Pre-existing on `main`; issue #123's
  fix stops the *stale* restore, not the second one.
- **A dead-but-retained card is blank after a reload.** The daemon's ring dies with
  the pty handle, so a card held open by a non-zero exit answers its post-reload
  request with empty bytes — the transcript that explains the failure is gone. The
  same applies to a term that exits during the request round-trip.
- **A rare one-chunk loss at the seam.** A chunk produced between the daemon's
  snapshot and the reply falls outside the snapshot and is discarded with the held
  buffer. Bounded to one chunk per mount; never a duplicate or a reorder.
- **No history from a pre-#41 daemon.** Such a daemon ignores the request; after a
  2 s bounded wait the card shows live output only, never a blank terminal.

## Observations

**2026-09-07, commit `3ff175a` — 4/4 PASS.** Run by the maintainer on the dev app
this worktree's `tauri dev` had rebuilt from the branch tip. Reported as a pass on
all four scenarios, assessed by eye; no readings were transcribed and no
screenshots were kept, so this entry is the whole of the record.
