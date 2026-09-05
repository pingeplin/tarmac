# Tarmac docs — index & classification

> **Doc status: ACTIVE** — start here.

Tarmac's docs accumulated across two UIs and five closed milestones, so a page's
*path* tells you nothing about whether it describes reality. Every doc therefore
carries a status banner on its first line, and this table is the map.

## The three statuses

| Status | Means | You may |
| --- | --- | --- |
| **ACTIVE** | Describes Tarmac as it is on `main`. Kept in sync with the code. | Cite it as current behaviour. Fix it when you change the code. |
| **PROPOSED** | A design for something **not implemented**. Zero lines of it exist. | Cite it as intent. **Never** as behaviour. |
| **HISTORICAL** | A frozen record of a closed milestone or a shipped change. Describes the code *as it was then*. Not maintained. | Read it for *why* a decision was made. Never infer current behaviour. |

Grep rule: `grep -l "Doc status: ACTIVE" docs/**/*.md` is the complete set of
pages you may trust for present-tense claims.

## What is enforced

`make docs-check` (also a required check on every PR, `.github/workflows/docs-check.yml`)
runs deterministic tripwires only — it never judges prose:

1. every doc carries a status banner;
2. every relative link resolves;
3. **ACTIVE** docs may not cite a source path that doesn't exist (HISTORICAL docs
   are exempt — naming dead files is their job);
4. every `Msg` variant in `tarmac-protocol` appears in both `architecture.md` and
   `protocol.md`.

On a PR it additionally *reports* (never fails) when an ACTIVE doc still names a
file the PR deleted. Prose that is merely out of date is out of scope — that
still needs a human or an agent reading the diff.

## ACTIVE

| Doc | What it is |
| --- | --- |
| [`../README.md`](../README.md) | Product overview, status, build & run. |
| [`../CLAUDE.md`](../CLAUDE.md) | Agent-facing repo brief: architecture, build, conventions, gotchas. |
| [`architecture.md`](architecture.md) | The engineering overview. The single normative description of how Tarmac works. |
| [`protocol.md`](protocol.md) | The authoritative wire contract + frozen conformance vectors. |
| [`workflow.md`](workflow.md) | issue → branch → worktree → commit → PR conventions. |
| [`backlog.md`](backlog.md) | The audited list of what is **not** built, and what was removed on purpose. Active *as a list*; its contents are unbuilt by definition. |

## PROPOSED — not implemented

| Doc | What it is |
| --- | --- |
| [`proposed/v4c-editable-docs.md`](proposed/v4c-editable-docs.md) | Editable doc cards, borrowed focus, write-conflict banner. Captured from mocks; never started. Doc cards are read-only today. |

## HISTORICAL

Frozen. Much of it describes the **Swift/AppKit + SwiftTerm** app that was
replaced by Tauri 2 + React + xterm.js in #27 (2026-06-29).

- [`archive/m0/`](archive/m0), [`archive/m1/`](archive/m1) — earliest visual cribs.
- [`archive/m3/plan.md`](archive/m3/plan.md) — the "strips = boards" milestone record.
- [`archive/v4/`](archive/v4) — the v3-grid → v4-whiteboard migration plan + visual crib.
- [`designs/`](designs) — one record per shipped change (numbered `YYMM.NNNN_*` plus a few named ones). These are *change* records: accurate about the change they accompanied, not about today. A design record for a change that was investigated but **not** built lives here too and carries a PROPOSED banner — read the banner, not the directory.
- `.blueprint/specs/` (repo root) — the per-issue implementation specs the design records are derived from. Same rule: historical.

## Milestone vocabulary

`M0`, `M1`, `M2`, `M3`, `v4` are **closed milestone names**, kept alive only by
archived plans and the `core/crates/tarmacd/tests/m{0,1,2,3}_integration.rs` file
names. `v4c` is a **proposal that was never started**. There is no `M4`, `M4c`,
or `v5` — if you see one, it is a hallucination or a typo for `v4c`. Work after
M3 is tracked per GitHub issue; see [`workflow.md`](workflow.md).

## When you add a doc

1. Put a status banner on line 3, right under the `#` title.
2. ACTIVE goes at `docs/` root; PROPOSED goes in `docs/proposed/`; a record of a
   change you just shipped goes in `docs/designs/` and is **born HISTORICAL**. A
   design record for a change you investigated but did **not** build also goes in
   `docs/designs/`, born **PROPOSED** — the banner is what classifies it, and it
   flips to HISTORICAL if the change later ships.
3. Add it to the right table above.
4. When a doc stops describing reality, flip it to HISTORICAL — don't leave it
   ACTIVE and stale.
5. Run `make docs-check`.
