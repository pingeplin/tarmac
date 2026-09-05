# Culled HTML card scheduler gate — manual QA checklist (spec 2609.0002, issue #72)

The [Q]-tagged scenarios S29–S39 the unit suites cannot cover: the React/Tauri shell
has no unit tests by design (only pure `kit/` logic and Rust are tested), and CPU is
not measurable from Vitest at all. Run against `make run` with a fresh dev daemon
(`make kill-daemon` first), or against a release bundle launched with the worktree's
`.dev/` socket and state for the CPU cells.

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`), since a
persistent installed daemon hijacks the dev app. For this sheet it matters twice over:
the CPU cells identify the WebContent and GPU XPC services by set-difference against
what was running *before* launch, so a second Tarmac (an installed build, or another
agent's QA app) both hijacks the daemon and makes the process attribution wrong.

## Status: VERIFIED — 11/11 PASS, S31 with a recorded deviation (2026-09-05, commits `c82f899` + `e6782da`)

**S29–S36 and S38–S39 ran and passed against `c82f899`. S37 failed there** — the
probe shipped with that commit was broken two independent ways (kept below as
history), so every behavioural cell in that pass ran a fixed scratch copy.
`e6782da` fixed both defects, and **S37 and S29 N=1 were re-run against the
shipped file**: S37 now PASSES and S29 N=1 reproduces with the committed probe
unmodified. The re-runs are the second Observation paragraph under each.

An independent review of this record then reproduced every cited number from the
screenshots and found seven claims that overstated or misdescribed what backs
them. **No result changed**; what changed is what the record asserts — S31 is now
PASS-with-deviation, S36's discriminating evidence is restated (its `zoom-mode`
clause was vacuous and is withdrawn), the CPU sampling caveats and the screenshot
guarantee are stated accurately, and two previously undisclosed deviations are
listed below. Everything below was observed on screen against a **debug**
build of `c82f899` — the PR's feature commit — driven through the real UI in
`../tarmac-worktrees/72-offscreen-card-throttle`. Screenshots are named in each
Observation and live outside the repo in `../tarmac-worktrees/qa72-scratch/shots/`,
alongside the raw CPU rows (`cpu.jsonl`) and the fixtures the run used.

How the session was set up, since six details deviate from this sheet's literal
instructions and a later reader needs to know:

- **The committed probe does not work in the app, so every behavioural cell ran a
  one-character-fixed copy.** `cull-probe.html:102` carries a literal `</script>`
  inside a `//` comment, which ends the script element there; the copy splits it
  as `<\/script>` and changes nothing else. Byte-for-byte that is the only edit —
  see S37. Cells that need `loops=none` (the S30/S32 baseline) additionally
  hard-code `String("?n=6&loops=none")` in place of `location.search`, because the
  URL switches are unreachable through `tarmac open` (also S37). The scheduler
  loops the CPU cells measure are identical either way, and the reporter runs in
  both arms of every marginal, so no CPU figure depends on the fix. **`e6782da`
  fixed the probe**; S37 and S29 N=1 were then re-run against the shipped file
  (see their second Observation paragraphs), so at least one gap cell on this
  sheet is taken with the committed artifact unmodified.
- **Daemon isolation was by socket, not by `pkill`.** The installed `tarmacd`
  belongs to a Tarmac the operator had open, so it was left running untouched; the
  QA app and every `tarmac open` used
  `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock`, served by this worktree's
  `core/target/debug/tarmacd` (`app connected (generation 1)` in its log). The CPU
  cells identify the WebContent/GPU/Networking services by set-difference against
  what was running before each launch, and drop the three long-lived services that
  predate the run.
- **The app was started from a hand-built wrapper bundle, not `make run`.**
  `qa72-scratch/TarmacQA72.app` (bundle id `com.tarmac.qa72dev`, process name
  `TarmacQA72`) wraps a copy of this worktree's own
  `desktop/src-tauri/target/debug/tarmac-app`, launched from a shell carrying the
  four `make run` env vars, with Vite serving the frontend on the usual port. The
  `tauri dev --config` route of issue #102 was tried first and **did not work**:
  the dev process reported `bundle identifier = missing value` and the process
  name `tarmac-app`, i.e. indistinguishable from the installed app by name and
  carrying no identifier at all — exactly the #89 hazard. The wrapper also made
  the QA app the only entry in the computer-use allowlist, which is what let the
  MCP screenshots exclude everything else. **The saved `.png` files come from
  `screencapture -x -R<window rect>` and carry no such compositor guarantee**;
  what backs them is procedural — the QA app was activated and its frontmost pid
  checked before each shot, the rect is that window's own geometry, and all 21
  files were opened and inspected afterwards. None shows the installed app.
- **Cull and un-cull were driven by a synthetic two-finger pan, not by ⏎/ESC.**
  50 wheel ticks ≈ 2000 world px at zoom 1, comfortably past the one-viewport
  margin; ⏎ (fly to the offscreen terminal) was used only where a single
  keystroke had to be timed exactly — the S30 gate and S34's pan-to-the-card. ESC
  never flew the viewport back in this environment, so it was not relied on.
- **⌘-chords only reach the app by key code.** `keystroke "k" using command down`
  and `keystroke "t" using command down` were both swallowed (the operator runs
  Karabiner-Elements); `key code 40 using command down` opened the switcher
  normally. S39's board switches used key codes plus arrow/Return — no socket
  driving was needed.
- **Board and card layouts were composed by writing `.dev/state.json`, not built
  through the UI.** `qa72-scratch/mk.py` writes each cell's tile geometry, doc list
  and saved viewport from a prototype the app itself produced, and the app is then
  relaunched onto it — the only way to place six cards on a 3×2 grid, put a card
  strictly over a hidden board's saved centre (S39), or park the prime terminal
  30 000 units away, repeatably. Everything *observed* was observed through the
  real UI afterwards: the cards are ordinary `tarmac-card://` doc cards, and the
  cull flips came from real pans and real board switches.
- **Two diagnostic screenshots show a stray select-all highlight.**
  `s39_switcher_probe.png` and `s39_kcode_probe.png` were taken while working out
  why `keystroke "k" using command down` did nothing; both show a full-page native
  text selection inside the QA window, cause not established (Karabiner is the
  likely culprit). Neither is cited as evidence for any scenario, nothing was
  observed outside the QA window, and no cited cell can be affected — every CPU
  rep and every gap cell relaunches the app onto a fresh state.
- **CPU cells are three reps each, medians reported**, two consecutive 10 s
  windows with window 1 opening at the ⏎ that culls the six cards, plus a 10 s
  visible window in the same run for S32. One-minute load average across the 36
  rows: **2.21–3.50** (`load0`/`load1` in `cpu.jsonl`). **The frontmost-pid guard
  fired on no row** — but note that `cpu.sh` *records* a frontmost mismatch into
  the row's `warn` field and does not abort on one, so that is a clean result, not
  an enforced invariant. **Three rows did warn**: 33–35 (`ungated`/`none`/rep 3)
  carry `warn:"nwc=2"`, because `lib.sh`'s `wk()` sorted pids with `sort -n` while
  `comm -13` needs lexicographic order, so after PID wraparound three long-lived
  services (`34529:gpu 34530:net 34533:wc`) leaked into that cell's class list.
  All three read 0.0%, and the published numbers are the ones you get once they
  are excluded. Both helpers have been corrected in the scratch dir — `wk()` now
  uses plain `sort`, and `analyse.py` attributes only services this app minted
  (`abs(pid - app) < 200`) instead of last-wins — so `python3 analyse.py cpu.jsonl`
  now reproduces the tables below as shipped. To check by hand instead, delete the
  three stale tokens from rows 33–35's `class` field.

**Companion artifact:** [`cull-probe.html`](cull-probe.html) — open it with
`tarmac open desktop/qa/cull-probe.html`. Its switches (`n`, `loops`, `across`,
`ms`) are **space-separated tokens in its `<meta name="cull-probe" content="…">`
tag** — not URL query parameters, which cannot reach a card (S37). Configure a cell
by editing that one line in a scratch copy; a six-card cell needs six copies anyway,
one per path:

```sh
for i in 1 2 3 4 5 6; do
  sed 's/content="n=1 loops=all/content="n=6 loops=all/' \
      desktop/qa/cull-probe.html > /tmp/cull$i.html
  tarmac open /tmp/cull$i.html
done
```

One file so configured serves every cell below. It reports through the console relay with
a `[cull]` prefix, one line per period, carrying each family's delivery count **and
max inter-delivery gap**, the real wall time `dt` the window covered, its card-side
outstanding-rAF count, and a boot id.

> ### The evidence is `gapRaf`/`gapInt`/`gapTo`, never the counts
>
> A paused card emits **no lines at all** — the reporter is a timer, so the gate
> pauses it too (a card cannot hold an un-gated timer; the shim wraps `setInterval`
> before the file's first byte, and an un-gated `MessageChannel` reporter would
> contaminate the CPU cells this same probe serves). So the first line after an
> un-cull spans the pre-pause remainder **plus** the whole cull **plus** the gap from
> resume to the next reporter tick.
>
> **A correct build therefore reports NON-ZERO counts on that line** — it includes the
> running periods on both sides of the cull. Scoring on counts would record a false
> FAIL. The decidable quantity is each family's largest interval between two
> consecutive deliveries:
>
> | | reading |
> |---|---|
> | **gate held (PASS)** | `gapRaf ≈ gapInt ≈ gapTo ≈ dt`, within ~2 report periods |
> | **a family leaked (FAIL)** | that family's gap stays **~1000 ms** (WebKit throttles an offscreen frame's timers to ~1 Hz) while `dt` runs to seconds |
>
> So `dt=8500 raf=15 gapRaf=8400 int=31 gapInt=8400 to=31 gapTo=8400` is a **pass**:
> 8.4 s with nothing delivered in any family. The same line with `gapTo=1000` is the
> failure, whatever its count says.
>
> There is deliberately **no card-side `gate=off` switch** — nothing a card does can
> bypass the shim; an un-gated baseline comes from a build with the gate reverted.

> **Read all three gaps, every time.** An **un-gated** culled card *already* shows a
> large `gapRaf` — WebKit services a non-visible frame only about once every 10 s —
> while its timers keep running at ~1 Hz. So `gapInt` and `gapTo` are the gate's only
> rate-level evidence. A cell scored on `gapRaf` alone would be recorded VERIFIED
> against a build in which the `cull` message never arrives at all.

---

## S29 — Culled cards deliver nothing (criterion 1)

- [x] Open one probe card (meta `n=1 loops=all`). Note its steady visible gaps
      (tens of ms).
- [x] Pan until it culls (more than one viewport out), hold it culled for ~10 s,
      then pan back. On the **first line after un-cull**, `gapRaf`, `gapInt` **and**
      `gapTo` are each within ~2 report periods of `dt` — all three, not just `gapRaf`.
      Ignore the counts on that line; they are expected to be non-zero.
- [x] Repeat with six probe cards (meta `n=6`) on a 3×2 grid; every card shows the same
      three-gap-≈-`dt` reading.
- [x] **The across-the-pause one-shot — mind the ordering, it is the whole cell.**
      The deadline is armed once at load and is fixed, so it discriminates nothing
      unless the cull actually *contains* it. **Cull the card within ~10 s of opening
      it, before any `ACROSS-FIRED` line appears, and hold it culled past the 12 s
      mark** — or set meta `across=<ms>` to a deadline you know your cull will
      span. Every report line carries `across=pending|fired`; if it already reads
      `fired` before you culled, the cell is void — reload and retry.
- [x] With that ordering satisfied, read the
      `[cull] ACROSS-FIRED at=… armedAt=… deadline=… elapsed=…` line: **`elapsed`
      must be visibly larger than `deadline`**, by roughly the part of the cull it
      waited through — that is a held-and-flushed timeout. An `elapsed` ≈ `deadline`
      means it fired on time, i.e. *while culled*, and is the failure. (Do not read
      the report counter for this: it is frozen during a cull, so both outcomes
      printed the same number.) This is the
      `setTimeout`-outstanding-across-the-pause case, which no measurement before
      this feature exercised.

Observation: **PASS.** N=1 (`s29_s31_n1.png`): the visible band reads raf 30/s
(`gapRaf` 35–47 ms), int 33–34/s (`gapInt` 31), to 33–34/s (`gapTo` 31–32); the
line straddling a 16 s cull reads
`t=7 dt=16710 raf=19 gapRaf=16089 int=21 gapInt=16093 to=21 gapTo=16093` — all
three gaps within 621 ms of `dt`, on non-zero counts exactly as this sheet
predicts. N=6 (`s29_n6.png`, all six cards in one frame; `s29_n6_precull.png` is
the same six running): `last dt` 15615–15621 against `gapRaf` 15088 and
`gapInt`/`gapTo` 15079 on every one of the six. The across-the-pause one-shot
satisfied its ordering precondition — every pre-cull line reads `across=pending` —
and fired at `elapsed=22714` against `deadline=12000`, i.e. held through the cull
and flushed at the un-cull. Cross-checked against the **un-gated** build on the
same machine 26 minutes later (16:33 → 16:58; `s30_ungated_leak_proof.png`): the same probe,
culled, reads `gapInt=1000 gapTo=1000` while `dt` runs to 2000, and its one-shot
fires at `elapsed=12002` — on time, while culled. That is the failure this cell
would have recorded had the gate not held.

**Re-run on `e6782da` with the committed probe unmodified** (`s29_n1_committed_probe.png`).
`qa72-scratch/v_default.html` is a `cp` of `desktop/qa/cull-probe.html`, verified
byte-identical with `cmp`; no meta edit, so it carries the shipped default
`n=1 loops=all across=12000 ms=1000`. Same big-card layout, same synthetic pan.
Visible band `t=3`–`t=8`: raf 30/s (`gapRaf` 35–45 ms), int 33–34/s, to 33–34/s
(`gapInt`/`gapTo` 31–32 ms). Straddling line:
`t=9 dt=16949 raf=26 gapRaf=16105 int=29 gapInt=16105 to=33 gapTo=16105` — all
three gaps within **844 ms** of `dt`. `across` read `pending` on every pre-cull
line and `ACROSS-FIRED` reports `elapsed=24374` against `deadline=12000`. The
shipped file now produces the gap cell on its own.

## S30 — Marginal CPU ≤ 1 point at every phase (criterion 3)

Sample **two consecutive 10 s windows, the first opening AT the pause** — not after
a settle. Baseline is the **same board with the probes' loops disabled**
(meta `loops=none`), not an empty board: it holds card count, DOM, iframes and layout
fixed and varies only the thing under test.

**The probe must not rely on WebKit's 10 s service tick**, which is undocumented,
unversioned, and re-anchors its phase on any delivered frame. A cell that settles for
≥12 s before sampling scores a *hold*-gate as passing — exactly the error the
out-of-repo harness made before it added two-window sampling.

- [x] N=6, `loops=all`, gated: window 1 marginal WebContent CPU ≤ 1 point.
- [x] N=6, `loops=all`, gated: window 2 marginal WebContent CPU ≤ 1 point.
- [x] Record the un-gated baseline **in the same session, on the same machine** —
      which means a second run against a build with the gate reverted:
      `git checkout 046f3bb -- desktop/src-tauri/src/card_shim.js`, rebuild, run the
      cell, then `git checkout HEAD -- desktop/src-tauri/src/card_shim.js` to restore.
      (Reverting only the shim is deliberate — checking out the whole parent commit
      would take the probe with it.) Expect
      roughly **+6 points**, which is #72 reproduced. There is no switch for this:
      nothing a card can do bypasses the shim. Without this cell the delta is
      being compared against a number from another machine.

Observation: **PASS at both windows.** Six 300×200 probes on a 3×2 grid,
marginal WebContent = `loops=all` − `loops=none`, medians of 3 reps per cell,
window 1 opening at the ⏎ fly-to-terminal that culls all six (raw rows:
`qa72-scratch/cpu.jsonl`, 36 rows; no row saw a frontmost mismatch, and the three
rows that warn `nwc=2` do so because of three stale pids in the set-difference —
see the CPU bullet in the preamble for the cause, the fix and the by-hand recipe).

| build | window 1 | window 2 | visible |
| --- | --- | --- | --- |
| **gated (`c82f899`)** | **−0.20** | **+0.10** | +8.88 |
| un-gated (`046f3bb` shim) | **+5.79** | **+6.69** | +8.48 |

Both gated windows are inside the ≤ 1 point bar. The un-gated cells reproduce #72
at the design's expected ≈ +6, in **both** windows — so this is not a build that
merely failed to receive the cull message: it was independently shown to leak
(`s30_ungated_leak_proof.png`, `gapInt`/`gapTo` pinned at ~1000 ms while culled)
before being used as a baseline. Absolute medians, WebContent / GPU / main:
gated culled `all` 1.50/0.30/0.30 then 0.30/0.00/0.10; un-gated culled `all`
8.29/0.70/7.19 then 7.79/0.50/7.29. Counted across all three processes the gate
recovers ≈ 13 points in window 1 and ≈ 14 in window 2, against the design's ≈ 11 —
larger because a debug build inflates the Tauri main process (+6.7/+7.0 here
against the design's +3.5). Criterion 3 counts WebContent only, so its verdict is
the table above. The shim was reverted with
`git checkout 046f3bb -- desktop/src-tauri/src/card_shim.js`, rebuilt, measured,
then restored with `git checkout HEAD -- …`; `git status` and `git diff --stat`
were both empty afterwards.

## S31 — Resume is prompt (criterion 4)

- [x] With a culled, paused card, pan back. **The first full one-second bucket that
      begins after the un-cull** already reads within the card's pre-cull band.

Observation: **PASS with a recorded deviation.** Same run as S29 N=1
(`s29_s31_n1.png`). Pre-cull band,
`t=3`–`t=6`: raf 30/s, int 33–34/s, to 33–34/s. `t=7` is the straddling bucket
(`dt=16710`) and is not read here. **`t=8` is the first full one-second bucket
that begins after the un-cull** — `dt=1007 raf=30 int=34 to=38`. raf and int are
inside the pre-cull band in that very first bucket. **`to` reads 38/s against a
33–34/s band, so the letter of the scenario — "within the card's pre-cull band on
all three counters" — is not met on the third counter.** The excess is the resume
flush: the timeout chain held across the pause is delivered in that bucket, and
the spec carves out no allowance for it, so it is recorded as a deviation rather
than waved through. It is an overshoot, not a shortfall — the card is back at (and
briefly past) its rate inside one bucket, which is what criterion 4 exists to
assert — and `t=9` is fully in band at 30/34/34. Nothing needed a second bucket to
come back to rate.

(Read the *counters* on this line, not its gaps: the probe reports the cull's own
gap twice, once as the still-open interval on `t=7` and once as the closed
interval on `t=8`, because `lastAt` is only advanced by a real delivery.)

## S32 — Nothing inside the margin changes (criterion 5)

Tolerance decided at the spec gate: **overlapping rate bands plus ≤ 1 point of
marginal WebContent CPU**. Take both halves in one session, on one machine.

- [x] A card that stays visible (or within the one-viewport margin) shows rate bands
      overlapping the same card measured with the gate reverted.
- [x] Its marginal WebContent CPU differs by ≤ 1 point from the same.

Observation: **PASS on both halves, taken in one session on one machine.**
*Rates:* gated visible band (`s29_s31_n1.png`) raf 30/s `gapRaf` 35–47, int
33–34/s `gapInt` 31, to 33–34/s `gapTo` 31–32; un-gated visible band
(`s30_ungated_leak_proof.png`) raf 29–31/s `gapRaf` 35–47, int 33–34/s `gapInt`
31, to 33–34/s `gapTo` 31–32. The bands overlap on all three counters.
*CPU:* marginal WebContent for the visible six-card board (`all` − `none`,
medians of 3 reps, same cells as S30's visible window) is **+8.88 gated against
+8.48 un-gated — a 0.40 point difference**, inside criterion 3's 1-point bar.
GPU and main marginals are identical to two decimals (+0.30 and +4.59 in both
builds).

## S33 — The round trip is invisible to the document (criterion 6)

**Use a card carrying an explicit `<meta name="tarmac-zoom" content="magnify">`** —
`magnify-probe.html`, or `cull-probe.html`, which carries one. Without the meta the
console line is never emitted at all (the host logs it only when `meta !== null`), so
"exactly one line" would be unfalsifiable.

- [x] Note boot id, `scrollY`, root zoom, the ICB probe's `offsetWidth` and the
      ~300-character wrap signature (`wrap-probe.html` decides wrap by character
      offset, not by eye).
- [x] Cull the card, then un-cull it.
- [x] All five readings are **identical**. In particular the **boot id is unchanged**
      — a cull round trip must never reload the document (#72's third acceptance
      bullet, and the #99 failure path).
- [x] The console strip still shows **exactly one**
      `zoom-mode declared=… effective=…` line — no second `ready` was honored.
      Cross-check `magnify-card-qa.md` S6 and S17.

Observation: **PASS.** Run on `s33probe.html`, a scratch fixture carrying
`<meta name="tarmac-zoom" content="magnify">` and reporting all five readings at
once (the committed probe carries the meta but reports nothing — S37).
Before (`s33_before.png`) and after a 14 s cull round trip (`s33_after.png`):

| reading | before | after |
| --- | --- | --- |
| boot id | `1788597472233.109600` | `1788597472233.109600` |
| `scrollY` | 160 | 160 |
| root zoom | 3 | 3 |
| ICB probe `offsetWidth` | 1000.0 px | 1000.0 px |
| wrap signature | `0,114,233 (chars=321)` | `0,114,233 (chars=321)` |

All five identical, and the "after" numbers are a *fresh* measurement — the
fixture re-measures on a gated 1 s interval that resumed with the card, and the
shot was taken four seconds after the un-cull. The boot id is unchanged, so the
round trip did not reload the document. The console strip holds exactly two
entries, one of which is the single
`zoom-mode declared=magnify effective=magnify` line; no second `ready` was
honored. `scrollY` was set by wheel-scrolling the selected card, not by script,
so a reload could not have reproduced it.

## S34 — P1: a card born culled never starts (criterion 7)

Worded as steady state on purpose: the card's script runs from load until the
`ready` → cull round trip completes, and the pause cancels what it issued. "Zero
callbacks ever" would fail a correct build — spec S34 asks for *at most its first
one-second bucket* to be non-zero.

- [x] Open a probe card onto a region of the board that is already culled. It emits
      its `[cull] boot=…` line, then falls silent.
- [x] Leave it culled ~10 s, then pan to it. On its **first line**, `gapRaf`,
      `gapInt` **and** `gapTo` are each within ~2 report periods of `dt`. **Its
      counts are non-zero by design** — that line carries the load burst before the
      `ready` → cull round trip landed, plus the post-resume gap — so score the gaps,
      never the counts.
- [x] Failure signals: a **second** reporter line covering the cull (it should have
      been silent throughout), or any gap sitting near **~1000 ms** while `dt` runs
      to seconds.

Observation: **PASS.** The prime terminal was parked at world (2500,−165) with
the viewport at the origin, then the probe was opened from the shell with
`tarmac open` — an unattributed open anchors on the prime, so the card landed at
(3056,−165) and was culled from birth — consistent with `mk.py`'s `bornculled`
layout, which parks the prime at (2500,−165) with the saved viewport at the origin
(`st_s34.json` is that pre-open layout; the landed doc tile is not in the evidence
dir).
After ~15 s culled, one pan brought it to centre. `s34_born_culled.png` is the
first frame after the un-cull: rAF **2 / 14827**, interval **0 / 14828**, timeout
**1 / 14828**, `last dt` **14828**, console badge **⌥ 4**. `s34_born_culled_console.png`
shows what those four entries are — `[cull] boot=…`, `zoom-mode`,
`[cull] t=1 dt=14828 raf=2 gapRaf=14827 int=0 gapInt=14828 to=1 gapTo=14828`, and
`ACROSS-FIRED`. **The first reporter line the card ever emitted is `t=1` and it
covers the entire cull**: no second line covered it, and no gap sat near 1000 ms.
The counts are non-zero by design (the load burst before the `ready` → cull round
trip landed) and `int=0` — zero interval deliveries across 14.8 s.

## S35 — P2: a `?v=` reload while culled comes back paused (criterion 7)

- [x] With a paused, culled probe card, rewrite its file so `lastChangedMs` changes
      and the iframe reloads via `?v=`. A new `[cull] boot=…` line appears (new boot
      id), then silence — no per-period lines.
- [x] Leave it ~10 s, then pan to it. On the first line under the **new** boot id all
      three gaps are within ~2 report periods of `dt`: the reloaded document came back
      paused, without any pan.

Observation: **PASS.** `s35_v_reload.png`. The card was culled, and 5 s later —
while culled — its file was appended to, moving `last_changed_ms` and bumping
`?v=`. The console shows the old boot id `…785574.230909` going silent after
`t=12`, then `[cull] boot=1788597802550.4013` with a second `zoom-mode` line
(expected: a `?v=` reload resets `readyHandledRef`), then **nothing for the rest
of the cull**. The first line under the new boot id reads
`t=1 dt=15381 raf=1 gapRaf=15381 int=0 gapInt=15381 to=1 gapTo=15381` — all three
gaps equal `dt` to the millisecond — and its `ACROSS-FIRED` reports
`elapsed=15382` against `deadline=12000`. The reloaded document came back paused
without any pan.

## S36 — P3: the #99-shaped self-reload comes back paused (criterion 7)

**Never run before.** The design infers this from the guard analysis; this is its
first verification, and it is the scenario that requires the cull post to sit
**before** the `readyHandledRef` guard rather than after it. It must hold under
either resolution of #99.

- [ ] With a paused, culled card, borrow it (double-click), open its console and
      **select the card's iframe as the execution context** — the top-document
      context makes this a silent no-op.
- [x] Run `location.reload()`. `src` and `lastChangedMs` are both unchanged, so
      `readyHandledRef` stays set. A new `[cull] boot=…` line appears, then silence.
- [x] Un-borrow, leave it culled ~10 s, then pan to it. On the first line under the
      **new** boot id all three gaps are within ~2 report periods of `dt` — the
      self-reloaded document came back paused.

Observation: **PASS — run here for the first time.** Driven by `s36probe.html`
(scratch fixture) rather than the borrow-and-console recipe, which cannot be
followed as written: a culled card is `visibility:hidden`, so it cannot be
double-clicked, and every timer a card can reach is already the shim's gated
wrapper, so a timed self-reload would never fire while paused. The fixture instead
listens for the host's own `{tarmac:"cull", culled:true}` and calls
`location.reload()` from that handler, guarded once by `window.name`. That is the
#99 shape exactly — same `src`, same `lastChangedMs`, so `readyHandledRef` stays
set. `s36_self_reload.png`: `[s36] culled -> location.reload() gen=1`, then
`[s36] boot=1788597902828.117413 gen=2`, then **silence**, then
`t=1 gen=2 dt=14598 raf=17 gapRaf=14063 int=18 gapInt=14062 to=23 gapTo=14062` —
all three gaps within 536 ms of `dt`.

**What discriminates the guard here is the silence, not the console.** An earlier
version of this observation claimed the absence of a second `zoom-mode` line as
positive proof; that was vacuous and is withdrawn. `s36probe.html` carries no
`<meta name="tarmac-zoom">`, so `readMeta()` returns `null` and
`HtmlCard.tsx:150` logs nothing for *either* generation — the absence is
guaranteed by the fixture, which is exactly the trap S33's own preamble warns
about. The discriminating evidence is the gap data. Under the "cull post placed
*after* the `readyHandledRef` guard" mutant the host returns early and never posts
to the reloaded document, so gen 2's fresh shim boots **un-gated inside a
non-visible frame** — the state measured directly on the reverted-shim build
(`s30_ungated_leak_proof.png`), where timers keep running at ~1 Hz. Its reporter
would therefore have ticked roughly seven times across the 14.6 s cull (the
un-gated reporter coalesces to `dt=2000`), each
line carrying `gapInt`≈1000. What was observed instead is **no reporter line at
all** between `[s36] boot=…gen=2` and a single `t=1` whose `dt=14598` says the
reporter itself did not run for 14.6 s. Only a document that received
`{tarmac:"cull", culled:true}` can produce that, and on a self-reload the sole
sender is a post that precedes the guard.

(The withdrawn clause also appears in commit `b5ed99f`'s message, which is
history and stays as written — but it must not be carried into the squash message
when this PR lands.)

## S37 — The probe is committed and instrumented (criterion 9)

- [x] `desktop/qa/cull-probe.html` is in the repo, installs its rAF/cAF
      outstanding-count wrapper as the **first statement of its own script**, and
      reports `outstanding=` in every line.
- [x] Its `n` / `loops` / `across` / `ms` switches all work — set in the
      `<meta name="cull-probe" content="…">` tag of a scratch copy — so one file
      serves every cell above.
- [x] The in-app numbers from this sheet are recorded in
      `../../docs/designs/2609.0002_offscreen_html_card_throttle.md` and summarised
      in `../../docs/architecture.md`.

> The **host page's** outstanding-rAF count is a different instrument and is **not**
> part of this scenario — it needs a wrapper in the host document before the app's
> own code runs. It is [#105](https://github.com/pingeplin/tarmac/issues/105).
> Nothing on this sheet turns "Tarmac is consistent with the isolated regime" into
> "established", and no observation below should claim it does.

Observation: **FAIL — two independent defects in the committed probe.**

1. **It never reports.** `cull-probe.html:102` contains a literal `</script>`
   inside a `//` JS comment
   (`// the whole shim + </script> before this file's first byte, …`). The HTML
   parser ends the script element there, regardless of the comment, so the
   outstanding-rAF/cAF wrapper IIFE — the whole of scenario (a) — **never
   executes**, `TM` is undefined, and the reporter, which is installed as
   `TM.setInterval.call(…)`, throws a `ReferenceError` before the final
   `console.log("[cull] boot=…")`. Observed (`s37_probe_broken.png`): every
   counter row reads `–` forever, the console strip holds exactly three entries
   (`Script error.`, `zoom-mode …`, one `ACROSS-FIRED`), no `[cull] t=…` line and
   no `outstanding=` is ever emitted, and the remainder of the truncated script
   renders as visible body text under the table. The loops themselves still run
   (they are set up before the throwing line), so the file is still valid for the
   CPU cells — but every gap-based cell on this sheet is unreadable with it. The
   fix is one character: `<\/script>`.
2. **The URL switches are unreachable.** `tarmac open` canonicalizes its argument
   and requires an existing file, so
   `tarmac open '…/cull-probe.html?n=6&loops=none'` is rejected outright
   (`No such file or directory (os error 2)`); and `cardSrcUrl`
   (`desktop/src/kit/docKind.ts:20`) percent-encodes the whole path into one URI
   segment and appends its own `?v=<mtime>`, so `location.search` inside a card is
   always exactly `?v=<mtime>`. Observed: a card opened from the committed file
   reads `cfg  n=? loops=all` — the defaults — and there is no supported way to
   reach any other value. One file therefore does **not** serve every cell; the
   `loops=none` baseline needed a copy with the query hard-coded.

Neither defect touched the feature under test — both were in the QA artifact.
That FAIL record is kept above as history; `e6782da` fixed both and the scenario
was re-run against the shipped file.

**Re-run on `e6782da`: PASS.** Every box now holds.

*It reports, with the outstanding-count wrapper live.* A card opened from a
byte-identical `cp` of `desktop/qa/cull-probe.html` (`s29_n1_committed_probe.png`)
emits, verbatim, first two lines:

```
[cull] boot=1788600136765.54162 n=1 loops=all across=pending acrossMs=12000
[cull] t=1 dt=1001 raf=1 gapRaf=1001 int=7 gapInt=834 to=12 gapTo=762 outstanding=1 across=pending n=1 loops=all boot=1788600136765.54162
```

— i.e. `t=`, `dt=`, all three gaps, `outstanding=`, `across=` and the meta's `n=`
and `loops=` echoed, on every line. (The `zoom-mode` line sits between those two;
it is the host's, not the probe's.) The counters no longer read `–` and no
`Script error.` appears.

*All four switches work.* Three cards on one board (`s37_switches.png`,
`s37_switches_console.png`), each a copy of the shipped file whose **only**
difference from it is the one `<meta name="cull-probe">` content line — confirmed
by `diff`, which prints exactly `104c104` for each:

| meta content | `cfg` echoed | rAF | interval | timeout | `last dt` | `outstanding` |
| --- | --- | --- | --- | --- | --- | --- |
| `n=1 loops=all across=12000 ms=1000` (shipped default) | `n=1 loops=all` | 30 | 34 | 34 | 1019 | **1** |
| `n=6 loops=none across=12000 ms=1000` | `n=6 loops=none` | **0** | **0** | **0** | 1020 | **0** |
| `n=3 loops=all across=3000 ms=500` | `n=3 loops=all` | 15 | 17 | 17 | **509** | **1** |

`n` is echoed; `loops=none` really stops all three families **and drops the
card-side outstanding count to 0**, which is what shows the rAF/cAF wrapper is a
live instrument rather than a constant; `ms=500` halves both `dt` and every
per-period count; and `across=3000` reaches the one-shot — that card's boot line
reads `acrossMs=3000` and its
`ACROSS-FIRED at=1788600207471 armedAt=1788600204470 deadline=3000 elapsed=3001`
fires at the meta's deadline rather than the default 12000. One file, edited only
in that tag, serves every cell above.

The third box was already met: the numbers are recorded in the RFC and summarised
in `architecture.md`.

> **Fixed by the `fix(qa): make cull-probe.html report and take its switches`
> commit; the re-run on `e6782da` above ticked every box.**
> The record above is kept as history; it is what the artifact did at `c82f899`.
> What changed:
>
> 1. The literal `</script>` at `cull-probe.html:102` is now spelled
>    `<\/script>`, so the first script element runs to completion, `TM` is
>    defined and the reporter emits `[cull] t=… gapRaf=… outstanding=…` lines.
> 2. **The switch mechanism is replaced, not repaired.** URL switches cannot work
>    through `tarmac open` + `cardSrcUrl` — the diagnosis above is exactly right —
>    so switches now live in a **`<meta name="cull-probe" content="n=1 loops=all
>    across=12000 ms=1000">`** tag, read with `document.querySelector`. That is the
>    mechanism already proven to survive this pipeline: it is how `tarmac-zoom`
>    reaches the shim. Configure a cell by editing that one line in a scratch
>    **copy** (a six-card cell needs six copies anyway, one per path):
>
>    ```sh
>    for i in 1 2 3 4 5 6; do
>      sed 's/content="n=1 loops=all/content="n=6 loops=all/' \
>          desktop/qa/cull-probe.html > /tmp/cull$i.html
>      tarmac open /tmp/cull$i.html
>    done
>    ```
>
>    The probe's header comment carries the same recipe, and every report line
>    still echoes `n=` and `loops=` so a cell stays self-describing in the log.
> 3. `desktop/src/cull-probe.test.ts` now loads the shipped file, parses it the
>    way an HTML parser would, and **executes both script blocks in a `node:vm`**,
>    asserting a real `[cull]` report line comes out carrying the gaps and the
>    meta tag's values. Both halves of defect 1 fail that suite, so a probe that
>    silently stops reporting can no longer reach a QA agent.

> Consistent with the note above, nothing in this run instrumented the **host**
> page's outstanding-rAF count (#105), and no cell here claims to have moved
> "Tarmac is consistent with the isolated regime" to "established".

## S38 — Cross-family flush order (pinned semantic 2)

The unit suite deliberately does not promise this: it is an engine property (a 0 ms
timeout runs before the next animation frame). Record it as observed.

- [x] With both a timeout and rAF callbacks held across a pause, the delivery log on
      resume shows the **timeout callbacks before the re-issued frame callbacks**.

Observation: **Timeouts before frames, as observed.** `s38_flush_order.png`,
driven by `s38probe.html` — a scratch fixture, because the committed probe reports
aggregate counts per period and cannot see order at all. It keeps exactly one rAF
and one 3 s `setTimeout` outstanding at every instant and stamps a monotonic
sequence number on whichever delivery shows a flush-sized gap. Across a 9 s cull
the log reads `3. TIMEOUT-FLUSH gap=9635` then `4. RAF-FLUSH gap=9092` — the
diverted timeout callback delivered ahead of the re-issued frame callback, which
is the engine property the unit suite deliberately does not promise. (Entry
`2. RAF-FLUSH gap=1694` is a launch artefact, not part of the flush: the window
was still occluded for its first ~1.7 s.)

## S39 — Non-active boards, and the documented gap

- [x] Put probe cards on a second board and switch away from it (App keeps every
      board mounted and hides the inactive ones with `display:none`).
- [x] Switch back after ~10 s: on each card the cull predicate reaches, the first
      line shows all three gaps within ~2 report periods of `dt` — they were paused.
- [x] **Record explicitly that the card straddling that board's saved viewport
      centre is NOT paused.** A `display:none` board delivers a `0×0` ResizeObserver
      entry, `visibleWorldRect` degenerates to a zero-area rect at `(cx, cy)`, and
      `rectsIntersect`'s strict `<` (`../src/kit/placement.ts:33`) leaves "the frame
      strictly contains `(cx, cy)`" as the surviving predicate. That is **already
      true today**, is **not** fixed by this change, and closing it would touch a
      predicate shared with terminal and markdown cards — it is
      [#104](https://github.com/pingeplin/tarmac/issues/104), deliberately out of
      scope here. Record the observation under #104.

Observation: **PASS on the pause half; the #104 card confirmed NOT paused.**
Board-1 held `all2.html` at world (−260,−200,420×400), which strictly contains
board-1's saved viewport centre (0,0), and `all3.html` at (170,−200,380×400),
which does not. Both ran at raf 30 / int 33 / to 33, `dt` ≈ 1000, while board-1
was active (`s39_board1_visible.png`). Board-0 was made active for 16 s
(`s39_board0_while_hidden.png`), then board-1 again; `s39_uncull.png` is the first
post-resume frame:

| card | rAF n / maxgap | interval | timeout | last dt | console badge |
| --- | --- | --- | --- | --- | --- |
| `all3` (culled) | 35 / **16196** | 39 / **16198** | 44 / **16173** | **17339** | ⌥ 57 |
| `all2` (straddles centre) | 31 / 34 | 34 / 31 | 34 / 31 | 1019 | ⌥ 91 |

`all3`'s three gaps are all within ~1.2 s of its `dt` — inside two report periods
— so it was paused for the whole hidden period. **`all2` was not paused at all**:
its gaps never left the 31–34 ms band and its `dt` stayed at one second. The
34-entry difference in the two console badges over the same lifetime is exactly
the reporter lines `all3` did not emit while paused (two hide cycles of ~16 s were
run; the table above is the second). This is
[#104](https://github.com/pingeplin/tarmac/issues/104) — a `display:none` board
reports a 0×0 viewport, `visibleWorldRect` degenerates to a zero-area rect at
`(cx, cy)`, and `rectsIntersect`'s strict `<` leaves exactly the frame that
strictly contains that point visible. Already true today, not changed by this
work, and recorded here as asked.
