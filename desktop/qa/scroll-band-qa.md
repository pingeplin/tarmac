# QA — white band while scrolling an HTML card (#142, spec 2609.0013)

Manual checklist for **S10 [Q]** and the `docs/coding-style.md` §1.3 exception-2
discharge owed by the `HtmlCard` wheel-relay wiring. The kit scenarios (S1–S7,
S9) are covered by `desktop/src/kit/cardZoom.test.ts`; this file covers what a
unit test cannot see — that the shipped wiring sends whole pixels, and that the
band is gone on real hardware.

## Why this needs a human (or a synthetic wheel)

The band is a compositing artifact: it does not reproduce in a headless browser,
whose screenshot path repaints in software and bypasses CoreAnimation tiling. It
has to be observed on screen, driven by real wheel events through the relay.

## Setup

1. `make run` from this worktree. It namespaces `TARMAC_SOCKET`/`TARMAC_STATE`
   per worktree, so it will not disturb an installed Tarmac.
2. Open a long, scrollable HTML card with **no** `<meta name="tarmac-zoom">`, so
   it takes the magnify default:
   `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock <worktree>/core/target/debug/tarmac open <file>`
3. Set the board to a **non-integer** zoom (e.g. 1.728). An integer zoom cannot
   reproduce the bug — `cardScrollDelta` divides by zoom, so only a non-integer
   zoom yields a fractional delta.
4. Select the card, so the wheel scrolls the document rather than panning.

`desktop/qa/scroll-band-probe.html` is a long scrollable document plus an overlay
that prints every relayed delta and whether all of them were integers; use it for
check 1. It is tracked next to this sheet (the `cull-probe.html` precedent) so any
future runner has it — an earlier draft pointed at `.dev/`, which is gitignored.

## Checks

| # | Scenario | What to do | Pass |
|---|---|---|---|
| 1 | wiring sends integers | scroll the `scroll-band-probe.html` card; read the overlay | `allInteger=true`, `fractional=0` |
| 2 | S10 — no band | scroll continuously ≥ 30 s **including direction reversals** | no white band at either edge, at any point |
| 3 | S4 observed | drag **as slowly as you can** on the trackpad — a crawl, a few px per second, small enough that each wheel event is a fraction of a pixel once divided by board zoom | the card still creeps; it never sticks at a standstill |
| 4 | no regression | zoom 100 % → 300 % → back | text stays crisp; no re-wrap at any step |

Check 4 is the guard on what magnify exists for. This change is orthogonal to the
zoom path by construction (S8), so a failure there means something unrelated
broke.

## Record

| date | build | zoom | check 1 | check 2 | check 3 | check 4 | by |
|---|---|---|---|---|---|---|---|
| 2026-09-09 | `fix/142-html-card-scroll-band` @ `6d3ef3c` + working diff | 173 % (1.728) | **pass** — `relay msgs=1874 lastDy=-1 allInteger=true fractional=0` | **pass** — no band | not run | **pass** — crisp, no re-wrap | EP Lin |

Check 1 is the strong one: 1874 relayed messages, every one integral, driven by
real wheel input through the shipped relay. `lastDy=-1` also shows single-pixel
steps being emitted, which is the carry doing its job at small deltas.

Check 3 is outstanding — the instruction was ambiguous on the first run and has
been reworded above. Its risk (a slow drag stalling because the residue is
discarded) is covered by S4 in `cardZoom.test.ts`; what is missing is only the
on-hardware confirmation.

> **Run 2026-09-09 for checks 1, 2 and 4 — see the Record below. Check 3 is
> still outstanding.** Synthetic input does not reach
> the Tarmac window on this machine. Measured with `cliclick` against the dev app
> (board at 173%, card centred and visible): pointer *movement* lands
> (`cliclick p` reports the new position) and `screencapture` sees the window
> fine, but synthetic clicks and scroll-wheel events change nothing — the card
> region stays pixel-identical (mean frame difference exactly 0.0) and the probe
> overlay records zero relayed messages. So checks 1-3, which all need real wheel
> input through the relay, cannot be automated from a shell here. Check 4 needs a
> human too (it is a judgement about crispness).
>
> Do not record a pass from a self-scrolling card: a card that calls `scrollBy`
> itself bypasses the wheel relay entirely, which is the code this change fixes.

## Known gaps, deliberately out of scope

- **A card's own fractional `scrollBy`** still bands (measured 126/200); this
  change only quantizes the relay path. Spec Open Question.
- **The borrowed path** (double-click, iframe receives native wheel directly)
  bypasses the relay and is unverified. The inferred mechanism is specific to
  programmatic scrolls, so it is expected to be unaffected — expected, not shown.
