# Card Focus Model for the Tauri Board

**Date:** 2026-06-28
**Status:** as-built
**Author:** EP Lin
**Doc type:** Reference

## TL;DR

The Tauri UI has **two independent "focus" concepts**, and keeping them separate is load-bearing:

- **Selection** — `selectedId: string|null` (`App.tsx:179`). The one card with the teal ring + raised-to-front z. Set on **grab** (pointerdown on header, resize handle, or card body).
- **Keyboard prime** — which terminal owns the keys (`prime`, `model.ts:68`). Set **only** on cycle / dock / board-switch / restore — **never on grab**.

Grab never calls `focusTerm`. That is the deliberate design that prevents clicking a doc card (or any card) from stealing keys away from a running agent in the prime terminal.

## Where focus state lives

- `selectedId: string|null` in `App.tsx:179` is the **sole** selection store — there is no `focusedId`.
- `prime` (`model.ts:68`) and `DockContext.dockedTermId` (`DockContext.ts:9`) are orthogonal; actual DOM keyboard focus is read **live** (`focusedLiveTermId()`, `App.tsx:282`), not stored.
- `CardModel.z` (`model.ts:65`, per-card, persisted) drives CSS `zIndex`; bumped alongside selection but independent of it. `topZ` folds across all card kinds.

## When focus is set

| Event | Result |
|---|---|
| pointerdown on header / resize handle | `onCardGrab(id)` → set `selectedId` + z=`topZ+1`; if a terminal, mark it prime (no `focusTerm`) — `CardShell.tsx:85`, `App.tsx:1439` |
| terminal body click | `onBodyPointerDown` → `onGrab` → set `selectedId` + z-raise (visual only; no `focusTerm`); xterm also self-focuses its textarea — `CardShell.tsx:164,188`, `App.tsx:282` |
| doc body click | `onBodyPointerDown` → `onGrab` → set `selectedId` + z-raise (visual only; no `focusTerm`) — `CardShell.tsx:164,188` |
| background pointerdown | `setSelectedId(null)` + blur active `.term-host` — `Board.tsx:123`, `App.tsx:1604` |
| ⌥Tab cycle | `setPrimeTerm(next)` + `focusTerm(next)` — `App.tsx:1297` |
| board switch (⌘K / daemon) | `setSelectedId(null)` + `focusTerm(docked ?? arrivedPrime)` — `App.tsx:953` |
| dock ⏎ / undock / restore (boot, ⌘N) | `focusTerm(...)` — `App.tsx:653`, `886` |
| Esc on focused doc | `'defocus'`: drops selection, swallows Esc — `escFocusAction.ts:14` |

## How focus is applied

- `selectedId` flows down as `selected={id===selectedId}`; **hidden boards always pass `selectedId={null}`** — `Board.tsx:166`.
- `selected` → `borderRole()` → teal ring + reveals resize handles — `cardChrome.ts:41,62`.
- Grab writes raised `c.z` into the card-layer wrapper's `zIndex`; `topZ` is global across terminals + docs — `Board.tsx:158`, `zOrder.test.ts:17`.
- `focusTerm(id)` calls the xterm `handle.focus()` (via `termHandlesRef`) with an rAF retry ≤5 frames — fired only on dock/cycle/switch/restore, **never on grab** — `App.tsx:267`, `TerminalCard.tsx:173`.
- **No daemon message on focus/grab** — selection + prime are pure client state — `App.tsx:1439`.

## Gotchas

- By design, `CardShell` is **non-focusable** (no `tabIndex`/`.focus`) so selecting a card can't steal keys from the prime terminal — `CardShell.tsx:5`.
- `CardShell.focused` prop exists but is **never populated** by Board/cards — always `false`; only `selected` is wired (both map to `'focus'`, so visually moot) — `CardShell.tsx:24`.
- `onBodyPointerDown` (body-select) is visual-only — calls `onGrab` but never `focusTerm`, so clicking any card body does not steal keys from the prime terminal — `CardShell.tsx:164`.
- `prime` is **border-inert** — signalled by header tint + shadow, not the ring. Exactly one live terminal is prime whenever any terminal is live — `cardChrome.ts:56`.
- Esc returns `null` for terminal / nothing-focused (only doc → `'defocus'`) so Esc keeps reaching the agent/vim — anti-regression tested — `escFocusAction.test.ts:12`.
