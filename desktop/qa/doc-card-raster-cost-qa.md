# Doc-card raster cost manual QA checklist (spec 2608.0002)

Companion to [`doc-prose-zoom-probe.html`](doc-prose-zoom-probe.html) (S6–S10)
and [`doc-prose-scaler-promotion-probe.html`](doc-prose-scaler-promotion-probe.html)
(S11, the R1 detector). These are the scenarios `make test` **cannot** decide —
Vitest has no layout, paint, or compositing engine (see the spec's "The
instruments, and what each tier can decide"). One slot per scenario S6–S13
below; fill in configuration and readings as you run each — **do not invent a
number you have not read**.

## Setup

- Tier 2 (S6–S10): the probe pages on a real engine — Playwright WebKit or
  system WKWebView. No `make run` / Tauri app required for these.
- Tier 3 (S11–S13): `make run`, fresh dev daemon. **Kill any installed
  `tarmacd` first** (`pkill tarmacd`) — a persistent installed daemon hijacks
  the dev app.
- Read `docs/designs/2608.0002_doc_card_raster_cost.md` before running
  anything — the "canonical table" (Finding 8) and its instrument caveats are
  the reference every reading below is compared against.

**Instrument warnings — carried from the design doc because getting them
wrong has already cost this repo a session:**

- **`ps -o rss=` is blind here and must not be used.** Composited backing
  stores are IOSurface-backed — the design doc measured K=3 → 363 MB, K=1 →
  390 MB, empty board → 364 MB, no signal either way. Use `footprint -p` on
  `com.apple.WebKit.WebContent` for process memory instead.
- **`LayerTree` alone is not sufficient.** It reported *zero* accumulation
  (14 → 16 → 14 layers, exactly) for the hover-scoped `overflow: auto` ratchet
  that `footprint -p` measured growing to 394 MB. Every memory claim below
  needs `footprint -p` beside layer state, not `LayerTree` in isolation.
- **Verify dpr at the window, not at the machine.** A prior session silently
  landed its window on a 1× external monitor and read a LONG base of 58 MB
  instead of 178 — pin the window to a screen with `backingScaleFactor ≥ 2`
  (or confirm `devicePixelRatio` in the page) before measuring anything below.
- **Absolute MB compares only within one session, never across.** The same
  base configuration has read 260, 246, and 261 MB in different sessions.
  Record the full configuration beside every figure; only deltas *inside* one
  pinned table are decision-grade.

**Canonical reference configuration** (Finding 8, design doc): dpr 2 verified
at the window, board zoom 1, K = 3, six 392×310 cards, 1400×900 window, macOS
26.6.1, SHORT and LONG corpora. Record your own actual configuration below —
it need not match this exactly, but must be pinned and stated.

- Date run: 2026-08-28, 08:30–08:55 CST — **one session**, every figure below
  captured inside it. Nothing here is compared against a figure from another
  session except where explicitly labelled "prior session".
- Machine / OS: Apple silicon (arm64), macOS 26.6.1 build 25G76. Two displays
  attached: built-in Liquid Retina XDR (2×) and an external BenQ EW2770QZ
  (1×, 2560×1440 native, "looks like" 2560×1440 → dpr 1). The 1× panel is the
  trap the dpr warning above describes; every reading below is on the 2× one.
- Engine(s) used (Engine A headless Playwright WebKit build / Engine B system
  WKWebView build): **both**.
  - Engine A = headless Playwright WebKit, playwright 1.62.1 / webkit-2336
    (`AppleWebKit/605.1.15 Version/26.5`), `deviceScaleFactor: 2`, driven over
    the Inspector `LayerTree` domain (`Layer.memory`, `compositedBounds`,
    `reasonsForCompositingLayer`).
  - Engine B = Apple system WKWebView (what Tauri/wry embeds) via the
    `wkhost2` Swift host, which pins its `NSWindow` to an `NSScreen` with
    `backingScaleFactor ≥ 2`, + `footprint -p` on
    `com.apple.WebKit.WebContent`.
- dpr, verified at the window: **2 on every row, both engines.** Engine A:
  `devicePixelRatio` read in-page on every arm (=2). Engine B: the `READY`
  line reports `dpr:2` on all 8 rows, and `hoverPre:0` on all 8 (no pointer
  contamination). `ps -o rss=` was not used anywhere; no `screencapture` was
  taken.
- Window size: 1400 × 900 on both engines.
- Corpus/corpora (SHORT / LONG / both): **both, but not on the same
  instrument** — and this is a limitation of the committed probe worth
  stating plainly:
  - `doc-prose-zoom-probe.html` (the committed instrument, used for S6–S9 and
    for S10(a)) is **single-corpus**. It has `?w=`/`?h=`/`?pre=` and no corpus
    length parameter, so it cannot produce a SHORT and a LONG row. Its one
    corpus is the 3-arm prose column at K=3, card 392×310, with three `<pre>`
    blocks: `pre0` (34-char non-overflowing null control), `pre1` (a genuinely
    overflowing 40-token flag line), `pre2` (a 200-char unbreakable token).
  - SHORT (`plen=1`) and LONG (`plen=10`) rows come from the six-card
    production replica used for the design doc's canonical table
    (`scratchpad/bound/replica.html`, 6 cards × 3 cols, 392×310), driven by
    `probe2.js` on Engine A and by `wkbatch-wrap.sh`/`wkrun2.sh` on Engine B.
    Every SHORT/LONG figure below is labelled with that instrument.
- Raw captures (ephemeral scratchpad, not committed): `r-qa-s6s10a.json`
  (committed probe, Engine A), `r-qa-s10a-replica.json` + `r-qa-s8-replica.json`
  (replica, Engine A), `wk-qa-s10b-dpr2.txt` (Engine B footprint),
  `r-qa-s11-noinject.json` + `r-qa-s11-replica.json` (R1).

## 2608.0002 S6 — prose blocks byte-identical between `base` and `wrap`, every sweep step

*Instrument:* `doc-prose-zoom-probe.html`, `armSignature()`.

- [x] Open the probe with `?pre=base`, pick one zoom-mechanism arm (use `C`,
      the shipped control — the only arm mirroring the real app), and via
      console run `window.__probe.run(z)` for `z` = 0.5, 1, 2, 3, 1 in order.
      Record `arms.C.sig` (every `h1`/`p0`…`p10` block) at each step.
- [x] Reload with `?pre=wrap`, repeat the same 0.5/1/2/3/1 sweep, record the
      same signatures.
- [x] **Pass iff:** every prose block's signature (everything except `pre`) is
      byte-identical between the `base` run and the `wrap` run, at every
      zoom step, on both corpora. Diffing the two full sweeps names `pre` as
      the *only* differing block.
- [x] The return leg to 0.5 is load-bearing (separates "re-wrapped once" from
      hysteresis) — do not skip it.

Reading — **PASS**:

- Committed probe (single corpus, Engine A, arm C = shipped control,
  `?pre=base` vs `?pre=wrap`, sweep 0.5 / 1 / 2 / 3 / 1 including the return
  leg, one page session per arm): the cross-arm signature diff names
  **`pre1` and `pre2` only, at all five steps**. Every prose block —
  `h2` `"0,25"`, `p1` `"0,58,114,165,215,265"`, `p2` `"0,47,106,165"`,
  `li1` `"0,41,85"`, `li2` `"0,46"`, `p3` `"0,49,98,150,201"`,
  `p4` `"0,57,112,158,202,249,295"`, `p5` `"0,55,101,150,197,251"` — is
  byte-identical between the two arms at every step, and so is `pre0`, the
  non-overflowing null control (`"0"` in both arms at every step). The return
  leg's z = 1 record is byte-identical to the outbound z = 1 record: no
  hysteresis.
  - *Deviation from the checklist's wording, not a failure:* this probe's
    corpus has **three** `<pre>` blocks, so "`pre` is the only differing
    block" reads here as "`pre1` and `pre2` only, `pre0` unchanged". `pre0`
    holding is itself a confirming reading — a `<pre>` that never overflowed
    does not move.
  - Zoom-mechanism arm B behaves identically. Zoom-mechanism arm A (issue
    #76's falsified CSS-`zoom` arm, **not** the shipped mechanism) additionally
    differs on `pre0` at z = 0.5 (`"0"` → `"0,12"`): arm A lays out at CSS
    `zoom: z`, so at z = 0.5 its prose column halves and `pre0`'s 34-char line
    wraps under `pre-wrap`. That is arm A's known layout instability, already
    the reason it was falsified; it says nothing about the shipped arm.
- SHORT (replica, 6 cards, `plen=1`, Engine A, same 0.5/1/2/3/1 sweep):
  **PASS** — differing block set is exactly `["pre"]` at all five steps, and
  the whole `wrap` signature is byte-stable across the sweep (as is `base`'s).
- LONG (replica, 6 cards, `plen=10`, 13 fingerprinted blocks `h1`,`p0`…`p9`,
  `pre`,`p10`, Engine A, same sweep): **PASS** — differing block set is
  exactly `["pre"]` at all five steps; both arms zoom-stable across the sweep.
- Cross-engine confirmation at z = 1 (Engine B, system WKWebView, dpr 2
  verified at the window): SHORT and LONG both diff to `["pre"]` only.

## 2608.0002 S7 — the `<pre>` signature changes exactly once, then holds

*Instrument:* `armSignature()` + per-block `scrollWidth`/`offsetHeight`, same
sweep as S6.

- [x] Across the same `base`→`wrap` comparison, the `pre` block's signature
      changes exactly once (base → chosen) and is then identical at every
      zoom step of the 0.5/1/2/3/1 sweep, on both corpora.
- [x] Record `offsetHeight` before (`base`) and after (`wrap`) — reference
      (design doc Finding 8, not a target to reproduce exactly): signature
      `"0"` → `"0,38,76,113,150,181,216,254"` (1 line → 8), `offsetHeight`
      143 → 643 K-px (+167 visual px per code block), `scrollWidth` 6257 →
      1044.

Reading — **PASS**:

- **Replica corpus (the one the design doc's reference figures were taken on;
  6 cards, Engine A, sweep 0.5/1/2/3/1) — reference reproduced exactly:**
  - pre signature base: `"0"` (1 line) / wrap: `"0,38,76,113,150,181,216,254"`
    (8 lines). Identical at all five sweep steps in each arm; changes exactly
    once, base → wrap.
  - offsetHeight before/after: **143 → 643** K-px (+500 K-px = +166.7 visual
    px per code block at z = 1). Constant across the sweep in each arm.
  - scrollWidth before/after: **6257 → 1044** (== `clientWidth` 1044: the
    overflow is gone, not hidden).
  - Engine B (system WKWebView) reads the same change with a one-px-per-line
    offset: `"0"` → `"0,39,77,114,151,182,217,255"`, also 8 lines. The design
    doc records the same Engine A / Engine B split, so this is engine text
    metrics, not drift.
  - `natH` (`.doc-prose` natural height) SHORT 1806 → 2303, LONG 12999 →
    13496 (Engine B READY lines, same session).
- **Committed probe corpus (`doc-prose-zoom-probe.html`, arm C) — invariant
  holds, reference figures do NOT reproduce, because the corpus is different:**
  - `pre1` (the genuinely overflowing block): sig `"0"` (1 line) → 19 lines
    `"0,39,80,119,160,198,239,275,311,347,383,419,455,491,527,563,599,635,671"`;
    offsetHeight **143 → 1428**; scrollWidth **16288 → 1044**.
  - `pre2` (the 200-char unbreakable token): sig `"0"` → `"0,41,82,123,164"`
    (5 lines); offsetHeight **143 → 429**; scrollWidth **4720 → 1044**.
  - `pre0` (null control): `"0"`, offsetHeight 143, scrollWidth 1044 ==
    clientWidth 1044 — unchanged in every arm at every step.
  - All three are byte-identical at every step of 0.5/1/2/3/1 within an arm,
    return leg included: **one change, then zoom-stable**.
  - *Disagreement with the design doc's reference, expected and recorded:*
    143 → 643 / 6257 → 1044 / 8 lines do not appear on this instrument. The
    committed probe's `pre1` is a 40-token `--flag-N=valueN` line — far longer
    than the replica corpus's `<pre>` — so it wraps to 19 lines instead of 8
    and starts from `scrollWidth` 16288 instead of 6257. The spec says
    character offsets are corpus-bound and the invariant is the pass
    criterion; that is what happened. It does mean **the committed probe
    cannot be used to check the design doc's S7 numbers** — only the
    invariant.

## 2608.0002 S8 — 200-char unbreakable token is reachable under `wrap`, not under `wrapx`

*Instrument:* probe per-block `scrollWidth`/`clientWidth` (the `pre-token` /
`pre2` block).

- [x] Under `?pre=wrap`, the 200-char-token block reads `scrollWidth ==
      clientWidth` — reference 1044 == 1044, every character reachable.
- [x] Under `?pre=wrapx` (`pre-wrap` without `word-break`), the same block
      reads `scrollWidth` **4693** against `clientWidth` **1044** — 4.5×
      overflow, clipped at the card edge, unreachable. (Reference figures;
      record what you actually read.)
- [x] **This is what makes `word-break` load-bearing, not cosmetic** — without
      it the chosen arm collapses to `clip`'s behaviour on exactly the lines
      that matter.

Reading — **PASS**:

- **Replica corpus, `tok=200` (the design doc's own instrument for this
  scenario; 6 cards, Engine A, dpr 2), reference reproduced to the byte:**
  - `wrap`: scrollWidth **1044** / clientWidth **1044** — equal, every
    character reachable. 1000 K-px tall.
  - `wrapx`: scrollWidth **4693** / clientWidth **1044** — 4.50× overflow,
    clipped at the card edge and unreachable. 714 K-px tall.
  - `clip` (control, for the "collapses to clip's behaviour" claim):
    scrollWidth **6242** / clientWidth **1044**, 215 K-px tall — i.e. `wrapx`
    genuinely lands in the same *unreachable* regime as `clip`, just with a
    shorter tail cut off.
  - `base` (`overflow: auto`, control): scrollWidth **6242** / clientWidth
    **1044** — overflow present but scrollable, which is what promotes the
    scaler.
- **Committed probe, `pre2` block (arm C):** `wrap` scrollWidth **1044** /
  clientWidth **1044** (5 wrapped lines); `wrapx` scrollWidth **4678** /
  clientWidth **1044**, and its signature stays `"0"` — one line, not wrapped
  at all. Same verdict; the 4678 vs the design's 4693 is the two corpora
  building their 200-char token from different alphabets, not a
  measurement disagreement.
- `word-break` is therefore load-bearing, confirmed on both instruments:
  removing it leaves a 4.5× horizontal overflow that the four nested clips
  make unreachable.

## 2608.0002 S9 — sizer/scroller geometry invariants (shipped mechanism, arm C)

*Instrument:* probe geometry readout (`natH`, `sizerH` read back from
`offsetHeight`, `scrollHeightFixed`, scroll-fraction round-trip via
`opts.scroll`). Evaluated on arm **C** (the shipped zoom mechanism) across each
`?pre=` spelling.

- [x] (a) `proseNatH` (`natH.C`) is zoom-invariant — unchanged across the
      0.5/1/2/3/1 sweep. **Not** a claim that `scrollHeight` is constant (it
      is not, in any arm — see the spec's premise section); `natH` is the
      zoom-invariant quantity.
- [x] (b) `sizerH` (read back from `n.sizer.offsetHeight`, not the input)
      equals `ceil(natH·z/K)` at every step. Reference: held 30/30 rows across
      every pre-spelling arm and zoom step (design doc Finding 8).
- [x] (c) `scrollHeightFixed == sizerH` exactly, at every step.
- [ ] (d) Using `opts.scroll` (a fraction), the stored scroll fraction
      round-trips; the worst drift is integer-`scrollTop` quantisation at
      z = 0.5, and should be *smaller* for `wrap` than for `clip` (taller
      document, more scroll range).

Reading — **PASS** (committed probe, arm C, Engine A, dpr 2, K = 3, card
392×310, sweep 0.5 / 1 / 2 / 3 / 1, all three `?pre=` spellings):

- natH invariant across sweep: **yes, 15/15 rows.** `base` natH = 3664 at
  every step; `wrapx` = 4949; `wrap` = 5234. Unchanged by z, return leg
  included. (The re-wrap raises natH by +1570 K-px on this corpus — that is
  S7's one-time reflow, not zoom drift.)
- sizerH == ceil(natH·z/K) at every step: **yes, 15/15 rows** (45/45 across
  the three spellings), read back from `n.sizer.offsetHeight`, not from the
  assigned value. `wrap`: z 0.5 → 873, z 1 → 1745, z 2 → 3490, z 3 → 5234,
  z 1 (return) → 1745. `base`: 611 / 1222 / 2443 / 3664 / 1222.
- scrollHeightFixed == sizerH: **yes, exactly, 45/45 rows.** Note this is
  `ceil(natH·z/K)` — it moves with z by design, exactly as the spec's premise
  section says. No constant-`scrollHeight` claim is made or observed.
- scroll-fraction round-trip drift: **round-trips; worst drift at z = 0.5, as
  predicted.** Target fraction 0.3698, arm C, read back as
  `scrollTop / scrollHeight`:

  | z | `base` fracBack (drift) | `wrap` fracBack (drift) |
  |---|---|---|
  | 0.5 | 0.368249 (−0.001551) | 0.368843 (−0.000957) |
  | 1 | 0.369067 (−0.000733) | 0.369628 (−0.000172) |
  | 2 | 0.369628 (−0.000172) | 0.369628 (−0.000172) |
  | 3 | 0.369541 (−0.000259) | 0.369698 (−0.000102) |
  | 1 (return) | 0.369067 (−0.000733) | 0.369628 (−0.000172) |

  Drift is integer-`scrollTop` quantisation and is **smaller for `wrap` than
  for the taller-document comparison at every z** — the predicted direction.
  - *Deviation from the checklist's wording:* (d) asks for `wrap` vs **`clip`**,
    but the committed probe has no `clip` spelling (`?pre=` offers only
    `base`/`wrapx`/`wrap`). The comparison above is `wrap` vs `base`, which on
    this corpus is the same document height as `clip` would be (`clip` and
    `auto` wrap identically; only the overflow spelling differs). A true
    `wrap`-vs-`clip` drift comparison needs the replica instrument, and was
    not run this session.

## 2608.0002 S10 — `scalerN == 0` at every step (a), process footprint (b)

*Instrument:* WebKit Inspector `LayerTree` for (a); `footprint -p` on
`com.apple.WebKit.WebContent` for (b) — **both are required**, per the
instrument warnings above.

**(a) is the sharp, binary criterion that decides this scenario.**

- [x] Open the probe. Six doc cards, both corpora, dpr verified at the
      window, a calibration row reproducing the `base` reading first.
- [x] For **each** step of the 0.5/1/2/3/1 sweep: call `window.__probe.run(z)`,
      inspect `.doc-prose-scaler` in `LayerTree` (the DOM is now at this `z`),
      call `window.__probe.setScalerN(n)` with what you observed, then call
      `window.__probe.run(z)` **again at the same `z`** — `run()` is
      idempotent per `z`, so this second call's record is built against the
      exact DOM state you just inspected, with your injection now fresh, and
      that is the record to keep. (The first `run(z)` call's own record
      always reads `scalerN: null` — it necessarily precedes the
      LayerTree check, since the DOM has to exist before you can inspect it.)
      The probe consumes each injection on the very next `run()` and reverts
      to `null` after, so a step you don't repeat this way reads back `null`,
      never a stale carried-over value from a different step — a sweep dump
      can no longer misattribute one LayerTree check to all five steps.
      Repeat inspect → inject → re-run at every step you want recorded.
- [x] Include the adversarial case: a `<pre>` that really overflows under
      `visible` (the 200-char-token block) — `scalerN == 0` must hold there
      too.
- [x] **Pass iff:** `scalerN == 0` and `.doc-prose-scaler` is absent from the
      layer tree at every step, including the adversarial case.

Reading — **(a) PASS**. Engine A, dpr 2, 1400×900, K = 3, `LayerTree` count of
composited layers whose node is the scaler, at every step of the
0.5/1/2/3/1 sweep. SHORT/LONG are the replica (6 × 392×310 cards,
`plen=1`/`plen=10`, `pre=wrap`); the committed-probe column is the
`inspect → `setScalerN(n)` → re-`run(z)` at the same z` dance from the
checklist above, per step, with the injection consumed by that step's kept
record:

| z | SHORT scalerN | LONG scalerN | committed probe `rec.scalerN` (`wrap`) |
|---|---|---|---|
| 0.5 | 0 | 0 | 0 |
| 1 | 0 | 0 | 0 |
| 2 | 0 | 0 | 0 |
| 3 | 0 | 0 | 0 |
| 1 (return) | 0 | 0 | 0 |
| adversarial (overflow pre) | 0 (`tok=200`, all 5 steps) | 0 (`tok=200`, all 5 steps) | 0 (`pre2`, the 200-char token, is in the corpus at every step above) |

**Positive controls — the zeroes above are a real negative, not a blind
detector.** Measured in the same runs, same session:

| control | scalerN | scaler `compositedBounds` | layer total |
|---|---|---|---|
| SHORT `base` (shipped `overflow: auto`) | **6** at all 5 steps | 1176×1813 | 240.44 MB @ z 1 |
| LONG `base` | **6** at all 5 steps | 1176×13064 | 157.41 MB @ z 1 |
| SHORT `base` + `tok=200` | **6** at all 5 steps | 1176×1885 | 253.76 MB @ z 1 |
| committed probe `?pre=base` | **2** at all 5 steps (zoom-arms B and C; arm A carries `transform: none`, so it has no compositing reason and correctly does not appear) | 1176×3684 / 1176×3664, 18.38 MB each | 90.26 MB @ z 1 |

Under `wrap` the layer is **absent from the tree**, not merely smaller:
`layerN` 26 → 14 on the replica (15 at z = 3 in both `wrap` and `clip` — a
card entering the viewport, not a scaler), and 12 → 4 on the committed probe.
`wrapx` reads identically to `wrap` on this criterion.

**(b) is corroborating — no numeric pass floor** (the design doc sets none;
inventing one here would be fabricated). It fails only if the drop is absent
or inside this session's own calibration spread.

- [x] `footprint -p` on `com.apple.WebKit.WebContent`, six cards, both
      corpora, same-session base row captured first.
- [ ] Reference (design doc Finding 8, canonical table — do not expect exact
      reproduction): Engine B base → chosen: SHORT **261 → 81 MB**, LONG
      **178 → 93 MB**. Engine A: SHORT **240.44 → 64.50**, LONG **157.41 →
      75.39**.
- [ ] **Expected, not a regression:** chosen arm costs **+6 MB (+7.9%)** vs
      `clip` on SHORT (attributed to `.doc-scroll`'s own tiled backing store),
      nothing on LONG. Also expected: footprint drifting **93 → 97 → 99 MB**
      over 48/96 scroll cycles (sub-linear, matched by controls under the same
      driver — `clip` 93 → 95, base 178 → 181 — and a rest re-read returning
      93). This is a scroll-position-dependent working set, not a leak.
      Contrast the disqualified `:hover` arm's real ratchet: +6.3 MB *per
      event*, to 394 MB.
- [ ] Known open gap, do not attempt to close it here: z = 0.5 process memory
      is unmeasured, and the 260-vs-246 base spread between earlier sessions
      is still open.

Reading — **(b) PASS** (corroborating; the drop is present and far outside
this session's spread):

Engine B, real system WKWebView via `wkhost2`, window pinned to the ≥2×
NSScreen, `dpr:2` reported by the page on every row, 6 × 392×310 cards, 3
cols, 1400×900, z = 1, K = 3, `footprint -p` phys_footprint of
`com.apple.WebKit.WebContent`, all 8 rows captured back-to-back in **one**
batch (`wk-qa-s10b-dpr2.txt`):

| arm | SHORT (`plen=1`) | LONG (`plen=10`) |
|---|---|---|
| `base` (shipped, same-session calibration row) | **254 MB** | **169 MB** |
| `clip` | 75 | 73 |
| `wrapx` | 80 | 73 |
| `wrap` (**the chosen arm**) | **80** | **73** |

- SHORT base → chosen: **254 → 80 MB (−174 MB, −68.5%)**.
- LONG base → chosen: **169 → 73 MB (−96 MB, −56.8%)**.
- Same-session calibration/base row: the `base` row above, captured first in
  the same batch on the same window. GPU/Networking helpers stayed at 13–21 MB
  and 6.4–6.7 MB on every row, i.e. the whole movement is in WebContent.
- Engine A, same session, layer-memory sums (sum of `Layer.memory`): SHORT
  base **240.44 → wrap 64.50**, LONG base **157.41 → wrap 75.39** — these
  reproduce the design doc's Engine A canonical figures **exactly**.
- Expected non-regressions, both observed: `wrap` costs **+5 MB vs `clip` on
  SHORT** (80 vs 75) and **0 MB on LONG** (73 vs 73) — the design's +6 MB /
  0 MB, within footprint noise. `wrapx` and `wrap` are indistinguishable on
  memory (80/80 SHORT, 73/73 LONG), as the design says: they differ only on
  the unbreakable token (S8).

**Disagreements with the design doc's canonical table — recorded, not
massaged.** The *deltas* reproduce; two of the four *levels* do not:

- SHORT base 254 MB here vs **261** in the design table (−2.7%); SHORT chosen
  80 vs **81**.
- LONG base 169 MB here vs **178** (−5.1%); LONG chosen **73 vs 93 MB**, a
  −21.5% level difference and the largest of the four.
- These are cross-session level differences, which the design doc and the
  warnings at the top of this file both say are not decision-grade (the same
  base configuration has read 260, 246 and 261 MB across sessions). Every
  comparison drawn above is within this one batch. The LONG `clip` row moved
  with the LONG `wrap` row (both 73, both 93 in the prior session), so the
  20 MB is a whole-session level shift on the LONG configuration, not a change
  in the chosen arm's cost relative to its controls.
- Known open gaps, untouched here as instructed: z = 0.5 process memory is
  still unmeasured (Engine B rows are z = 1 only), and the 260-vs-246 base
  spread across earlier sessions is still open — this session adds 254 as a
  third SHORT base level, which widens rather than closes it.
- The 48/96-cycle scroll-drift rows (93 → 97 → 99) were **not** re-run this
  session; the prior session's ratchet batch stands unrepeated.

## 2608.0002 S11 (R1) — hostile markdown re-promotes `.doc-prose-scaler` (Tier 3)

*Instrument:* [`doc-prose-scaler-promotion-probe.html`](doc-prose-scaler-promotion-probe.html)
(the standing R1 detector) + `footprint -p`. **Not** Vitest — it can pin the
rule text (S1/S2) but can never observe promotion. This is the invariant with
no code guard: raw HTML in markdown carrying `will-change` or a 3D transform
silently re-promotes the subtree, degrading to the pre-2608.0002 cost, never
worse.

- [x] Open `doc-prose-scaler-promotion-probe.html`. In WebKit Inspector,
      select each case's `#scaler-<id>` element and check `LayerTree` for
      whether it has its own composited layer.
- [x] Call `window.__promotionProbe.report(caseId, composited)` for each case
      with what you observed; the page paints the verdict and is never a
      self-report.
- [x] **`clean` and `overflow-pre` expected NOT composited** — this is the
      change this spec buys, and `overflow-pre`'s 200-char unbreakable token
      is the adversarial case (content that would have overflowed under the
      old `overflow: auto` spelling).
- [x] **`will-change` and `transform3d` expected COMPOSITED** — this is R1
      itself: the raw-HTML vector the detector exists to catch, not a defect
      in this change. (First pass on the as-committed page found `will-change`
      a false negative — see "Bug found and fixed" below. Confirmed COMPOSITED
      after the fix, in "Re-verification after the fix".)
- [ ] Separately, in the real app (`make run`): open a markdown doc whose raw
      HTML carries `will-change` or a 3D transform as a doc card, and confirm
      by `footprint -p` that its footprint matches the "composited" cost, not
      the de-promoted one. Reference (design doc): **59.69 → 238.55 MB** on
      Engine A (read the ~4× ratio, not the levels — card count/corpus behind
      that pair were not recorded, so do not expect to reproduce it exactly).
      **TODO — not run this session**, human-hands-on-GUI item, see "Real-app
      footprint check" below.

Reading — **PASS, after fixing a false safe in the detector page itself.**
All five cases (four original + one added control) now report the verdict
the detector's own doc comment expects. The bug and fix are kept below,
in full, as the record of what this detector already caught once.

**Driven on Engine A**: headless Playwright WebKit, playwright 1.62.1,
webkit revision 2336 (`AppleWebKit/605.1.15 Version/26.5`), viewport
1400×900, `deviceScaleFactor: 2`. dpr verified at the window (not the
machine): `devicePixelRatio` read back in-page as `2` for every case, on
every run. macOS 26.6.1 build 25G76, arm64.

### Bug found and fixed: `will-change` case was a false safe

First pass, on the detector exactly as originally committed, before any file
was touched — same config as above: `clean` not composited (correct),
`transform3d` **COMPOSITED**, `compositedBounds` 1080×1045, 17.22 MB, reason
`overlap` (correct — this is R1, reproduced), `overflow-pre` not composited
(correct) — but `will-change` also read **not composited**: **expected
COMPOSITED and it was not — a false safe on half of R1's surface.**

Diagnosed the same session (three runtime-only patches, no file edited yet):
the case's hostile element was `<span style="will-change: transform">` — a
*non-replaced inline* box, and `transform` does not apply to those, so
WebKit ignores the hint and nothing promotes. Patch it at runtime and it
promotes immediately:

| runtime patch on `[data-hostile="will-change"]` | scaler composited | `compositedBounds` | layer |
|---|---|---|---|
| none (as originally committed) | **no** | — | absent |
| `display: inline-block` | **yes** | 1080×1003 | 16.53 MB, reason `overlap` |
| `will-change: opacity` (applies to inlines) | **yes** | 1080×1003 | 16.53 MB, reason `overlap` |

Corroborated on six real doc cards (replica, Engine A, same session,
`pre=wrap`, raw-HTML block injected into the prose — `raw=wc` is
`will-change: transform`, `raw=tf` is `translateZ(0)`, both on a `<div>`):

| arm | total layer MB | scalerN | scaler `compositedBounds` |
|---|---|---|---|
| SHORT `wrap` (baseline) | 64.50 | 0 | absent |
| SHORT `wrap` + `raw=wc` | **149.07** | **6** | 1176×2415, 18.38 MB each |
| SHORT `wrap` + `raw=tf` | **149.07** | **6** | 1176×2415, 18.38 MB each |
| LONG `wrap` (baseline) | 75.39 | 0 | absent |
| LONG `wrap` + `raw=wc` | **149.07** | **6** | 1176×13665, 18.38 MB each |
| LONG `wrap` + `raw=tf` | **149.07** | **6** | 1176×13665, 18.38 MB each |

A single raw-HTML block re-promotes **all six** scalers: **2.31× on SHORT**
(64.50 → 149.07) and **1.98× on LONG** (75.39 → 149.07). `will-change` on a
block element behaves exactly like `translateZ(0)` — identical to the byte —
confirming the detector's miss was about the `<span>`, not about
`will-change`.

**Fix applied to `doc-prose-scaler-promotion-probe.html`:** the `will-change`
case's hostile node is now `<div style="will-change: transform;
display: inline-block;">` — a block-context box, the same spelling
`transform3d` already used, so the hint actually applies. Added
`will-change-inline`, a new, explicitly-labelled case that keeps the
original inert `<span>` as a **control** (a genuine non-promoter, not a
second hazard) — so "inline `will-change` does nothing" is recorded as a
fact, not mistaken for missing R1 coverage.

### Re-verification after the fix

Same config as above (Engine A, playwright 1.62.1 / webkit 2336, 1400×900,
dpr 2 verified in-page), driven twice back-to-back for determinism —
identical both runs:

| case | expected | observed | `compositedBounds` | layer MB | reason |
|---|---|---|---|---|---|
| `clean` | NOT composited | **not composited** | — | — | — |
| `will-change` | COMPOSITED | **COMPOSITED** | 1080×1117 | 18.40 | `overlap` |
| `will-change-inline` (new control) | NOT composited | **not composited** | — | — | — |
| `transform3d` | COMPOSITED | **COMPOSITED** | 1080×1045 | 17.23 | `overlap` |
| `overflow-pre` | NOT composited | **not composited** | — | — | — |

All five cases now report the verdict the detector's own doc comment
expects. `transform3d`'s numbers are within noise of the first pass
(17.22 → 17.23 MB, same 1080×1045 bounds — unaffected by the `will-change`
fix). `will-change`'s `compositedBounds` (1080×1117, 18.40 MB) differs
slightly from `transform3d`'s (1080×1045, 17.23 MB) because each case's
raw-HTML node sits in a different position within its own prose block — a
content-layout difference between the two cases, not a difference in
promotion. It also differs from the diagnosis table's runtime-patch reading
above (1080×1003, 16.53 MB) for the same reason: that patch flipped the
original `<span>` in place inside `p1`, whereas the applied fix moved the
hostile node to its own block position (mirroring `transform3d`'s markup
shape), so the surrounding prose reflows differently. Both are genuinely
COMPOSITED with reason `overlap`; only the box size moves, not the verdict.

- Real-app footprint check (if run): **TODO — not run.** This sub-item needs
  `make run` with a fresh dev daemon and a markdown doc card, i.e. human hands
  on the GUI app; it was deliberately left for the human, like S12/S13. The
  design doc's 59.69 → 238.55 MB (~4×) reference is therefore unconfirmed in
  the real app; the ~2× ratio measured above (corroboration table) is Engine A
  on six replica cards and is not the same measurement.

## 2608.0002 S12 (R2) — 1× crispness (Tier 3, UNKNOWN going in)

*Instrument:* by eye under `make run`, same procedure as
[`one-x-display-crispness.md`](one-x-display-crispness.md).

- [ ] Confirm a true 1× panel via `system_profiler SPDisplaysDataType` (no
      "looks like" resample — native resolution, no macOS scaling).
- [ ] Open a doc card with code blocks. Read it at board zoom 0.5, 1, and 2.
- [ ] **Pass iff:** glyphs are no softer than before this change, at each
      zoom level tested.
- [ ] Known open gap: a real compositor capture of the `clip` arm read 1.2%
      mean luminance difference and **−1.6% sharpness** against base — real,
      pixel-aligned, not a registration artifact — but has **no K=1
      calibration**, so how much is inherent to compositing vs. caused by
      de-promotion is unknown. "Indistinguishable at 2×" is the strongest
      claim available going in, and it is a 2× claim only. Record "no
      regression observed" here, not a proof.

Reading — **TODO, deliberately left open for a human.**

- 1× panel model/config: TODO — a candidate is attached (BenQ EW2770QZ,
  2560×1440 native, no macOS scaling, dpr 1), but crispness cannot be decided
  by an instrument.
- Verdict at zoom 0.5 / 1 / 2: TODO / TODO / TODO — **requires `make run` and
  human eyes.** No automated run was made and none should be recorded here;
  the only honest reading of this scenario comes from looking at it.

## 2608.0002 S13 (R3) — gesture feel (Tier 3, UNKNOWN going in)

*Instrument:* by hand under `make run`.

- [ ] Board of de-promoted doc cards. Pinch-zoom and pan continuously across
      0.5 → 3 → 0.5.
- [ ] **Pass iff:** it feels no worse than before this change.
- [ ] Known open gap: the only frame timing available was headless under a
      30 fps cap — p99 38 ms for the de-promoted arm vs. base's 49 ms, which
      is "no regression detected", not a win. Record "no regression
      observed" here, not a proof.

Reading — **TODO, deliberately left open for a human.**

- Verdict: TODO — **requires `make run` and a hand on the trackpad.** Gesture
  feel has no instrument in this repo; nothing was run and nothing is claimed.
