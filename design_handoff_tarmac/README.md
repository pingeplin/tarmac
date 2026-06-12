# Handoff: Tarmac — agent cockpit for macOS

## Overview

Tarmac is a macOS app: a terminal-first cockpit for working alongside CLI agents (Claude Code etc.). The terminal is the primary surface; markdown docs that agents (or the user) open via a `tarmac open` CLI appear as summonable viewers beside it. The app deliberately has **no agent harness** — it never wraps, parses, or impersonates the agent. Every UI signal maps to an observable OS-level fact.

This package contains the final design (v3, "no-harness") plus an interactive HTML prototype and the cold-start flow.

## About the Design Files

The files in this bundle are **design references created in HTML** — prototypes showing intended look and behavior, **not production code to copy directly**. The task is to recreate these designs in the real app environment. No target codebase exists yet. The stack and architecture have since been decided — see **"Implementation decisions (v1 build)"** at the end; the design itself (tokens, states, choreography) is unchanged by those decisions.

## Fidelity

**High-fidelity.** Colors, typography, spacing, radii, and all states are final and should be matched closely. The interactive prototype additionally demonstrates intended interaction *feel* (peek slide-over timing, drag-swap, toast cadence); treat its JS as behavioral spec, not implementation.

## Core model (read this first)

1. **Terminal is the body; docs are summons.** The app launches as a bare shell. Docs exist in three states:
   - **dock** — collapsed left strip of doc icons (the index)
   - **peek** — slide-over panel; *focus never leaves the terminal*; `esc` dismisses
   - **pin** — doc becomes a tile on the desk, a peer of the terminal; tiles drag-swap
2. **No harness — four honest signals only:**
   | UI mark | Observable fact | Source |
   |---|---|---|
   | ⠧ spinner + process name + elapsed | foreground process still running | process table (`tcgetpgrp` per pty) |
   | cyan dot on doc icon/tab | doc was opened via `tarmac open` | CLI call (unix socket) |
   | cyan halo pulse (2.4s, ~30s decay) | file changed on disk | FSEvents/fswatch mtime |
   | amber dot | background terminal rang a bell | BEL character in pty stream |
   The UI never claims "agent is working/waiting" — it shows `claude · 4m12s` (a process) and `bell · infra` (a fact). Copy in metadata says "✎ 5s · **during** claude" (temporal correlation, never causation).
3. **Interface grows from facts.** No welcome screen, no setup. The dock does not exist until the first `tarmac open`. Strips (sessions) auto-name from the cwd repo.
4. **Strips** = named sessions (flight-strip metaphor). Each strip holds its terminals (tmux-backed), open docs, pinned layout. Restore brings the whole desk back.

## Screens / Views

### 1. Runway (default view)
- **Layout**: vertical stack — titlebar (40px) / main row / status bar (27px). Main row: left dock (46px) + desk (terminal fills it) + optional right rail (252px).
- **Titlebar**: traffic lights, session chip (`▞ infra-week`, mono 11px, bg2 bg, 5px radius), right-aligned process chip.
- **Terminal**: bg `#0a0c10`; tabs across top (mono 10.5px, active tab joins body via top:1px trick); body mono 12px / line-height 1.75, padding 12px 16px. Terminal tab label = **foreground process name + cwd repo** (`claude · payments-api`), updates live. Supports tabs + horizontal splits (1px line, 36px grab nub).
- **Doc links in output**: any path matching open-doc set is linkified — cyan, dashed underline; hover = solid underline + cyan tint bg; ⌘click → peek. Pure regex (like iTerm semantic links).

### 2. Dock (left, 46px)
- 30×30px icons (¶ glyph, 7px radius), repo-color dot top-left (7px), cyan dot top-right if opened-via-CLI and unread, amber dot if that doc's terminal bell is pending. Hover: bg3 + border. Active/pinned: bg2 + border. File-change: dockPulse halo ×3.
- Vertical "⌘E index" hint at bottom; ▞ glyph footer.
- **Dock is absent entirely until the first doc opens.**

### 3. Index (⌘E, expands dock to 224px)
- Groups by repo: header row = repo dot + repo name (mono 10.5px), items indented 22px (mono 11px), active = bg2. Same provenance dots as dock. Footer hints: `⏎ peek · ⌘⏎ pin`; strip name at bottom.

### 4. Peek (slide-over)
- Width 47% default (user-resizable 36–62%); slides from right, 220ms cubic-bezier(0.2,0.8,0.2,1); shadow `-26px 0 60px rgba(0,0,0,.55)`; z above desk.
- Header 36px bg2: repo dot + full path (mono 11px) + honest meta (`✎ 5s · during claude`, cyan 85% opacity) + kbd buttons `⌘⏎ pin` / `esc`.
- **Focus rule: opening a peek never moves keyboard focus out of the terminal.**

### 5. Desk + pinned tiles
- Desk = CSS grid, 12px padding, 10px gap, bg0. Tile = bg1, 1px `--tm-line` border, 9px radius; 28px header (bg2): kind glyph (¶ or ›_), repo dot, path, honest meta right-aligned, ✕ unpin.
- Grid by tile count: 1 → `1fr`; 2 → `1.35fr 1fr`; 3 → `1.35fr 1fr` cols ×2 rows, first tile spans rows; 4 → `1.25fr 1fr` / `1.3fr 1fr`.
- **Drag**: grab tile header → tile lifts (shadow `0 18px 44px rgba(0,0,0,.6)`, −0.5° rotate, follows pointer); hovered target gets 1.5px dashed cyan border; release swaps slots. Terminal tile drags too. (Prototype implements swap only; edge-split drop is designed — dashed cyan zone preview — but optional for M1.)
- Layout persists per strip.

### 6. Right rail (252px, toggleable)
- Three capped sections (mono 9.5px caps, 0.12em tracking, faint):
  - **STRIPS · ⌘K** — rows: ▞ glyph + name + meta (running count / `● detached` amber). Active = bg2 + border.
  - **PROCESSES** — rows: state icon (⠧ cyan / ◉ amber / ✓ green / · faint) + `name — repo` + timestamp line. Click → jump to that terminal tab.
  - **FILE EVENTS · fswatch** — `✎ repo/file` + `14:02 · during claude`. Click → peek. Newest first, newest highlighted.

### 7. Strip switcher (⌘K)
- Veil `rgba(8,10,13,.62)`; palette 480px, top 84px centered, bg2, 12px radius, shadow `0 24px 60px rgba(0,0,0,.6)`. Input row 13px mono with blinking cursor. Rows: ▞ + name + meta (repo dots, doc/term counts, tmux ✓ or amber `detached`). Footer: `⏎ switch · ⌘N new strip · ⌘⌫ archive`.

### 8. Session restore
- On relaunch: desk renders dimmed (35% opacity) under veil; centered card (bg2, 12px radius, 22×26px padding) lists restore facts: `✓ 6 docs · 3 repos`, `✓ tmux attached · 2 windows, history intact`, `→ agent was waiting on you · since 13:47`. "any key to continue". Detached strip shows `$ tarmac attach <name>` empty state instead.

### 9. Cold start (see Cold Start Flow.html)
1. Fresh launch = bare shell + one-line hint under prompt: `docs appear when anything runs tarmac open <path> — you or your tools` (shown once, never again).
2. `cd` + run claude → strip renames `strip-1` → repo name (first auto-name only; never renames after).
3. First `tarmac open` → dock is born (slides in) + toast `first doc · <path>` with `⌘P peek`.
4. First peek → user has now met shell/dock/peek; pin & strips taught on use.

## Interactions & Behavior

- **Keyboard**: `⌘P` peek most-recently-changed doc · `⌘E` toggle index · `⌘K` strip switcher · `⌘⏎` pin/unpin peeked doc · `esc` close peek/switcher/toasts · `⌫` (after auto-switch) return.
- **Focus-stealing policy**: while user is interacting, agent-driven events only mark (dots/pulses/toasts). If user idle ≥3min (configurable), a `tarmac focus` call may switch the active view, but must show a banner: `▞ agent switched to <doc> — you were idle 4 min` + `⌫ go back`. Never steal focus from typing. Never move the user's scroll position; doc rewrites keep reading position, show cyan-tinted changed sections (left 2px cyan border + gradient fade), and a bottom pill: `✎ rewritten · your place kept · changes above`.
- **Toasts**: bottom-right inside window, max 3 stacked, auto-dismiss 7s, enter 180ms slide-up. Used for: doc opened via CLI, process exit (`claude exited 0 · 6m24s` + `N open docs changed during the run`), first-doc moment.
- **Bell**: amber dot on terminal tab + dock + process rail; cleared by focusing that terminal. The **only** attention-pulling state; may badge the macOS dock icon.
- **Pulse decay**: file-change halo animates 2.4s ease-out, ×3 max (~30s of being noticeable), then falls back to a static state.
- **Reduced motion**: all blinks/pulses/slides gate on `prefers-reduced-motion`.

## State Management

Per app: strips map, active strip id, tweakable prefs (accent, peek width, rail visibility).
Per strip: terminal sessions (tmux window refs), dock doc list (ordered), pinned tile order, active terminal tab, peeked doc.
Per doc: path, repo, repo color index, openedVia (`cli`|`user`), read flag, lastChangedAt, changed-during-process name.
Derived (never stored as "agent state"): foreground process per pty, elapsed, exit code, bell pending, file events log.

## Design Tokens

Fonts: UI = system SF Pro stack; mono = IBM Plex Mono (400/500/600).

| Token | Value | Use |
|---|---|---|
| bg0 | `#0c0e12` | window/desk backdrop |
| bg1 | `#12151a` | panes, doc viewer |
| bg2 | `#191d24` | raised: tabs, cards, chips |
| bg3 | `#20252e` | hover |
| term-bg | `#0a0c10` | terminal body |
| line | `#262c36` | strong borders |
| line-soft | `#1d222b` | hairlines |
| text | `#d8dbe2` | primary text |
| muted | `#8c93a0` | secondary |
| faint | `#5a616d` | tertiary/hints |
| agent (accent) | `oklch(0.78 0.11 200)` | cyan — anything CLI/file-event touched |
| agent-dim | `oklch(0.78 0.11 200 / .16)` | tints |
| amber | `oklch(0.78 0.11 75)` | bell / waiting |
| ok | `oklch(0.75 0.1 150)` | success/exit 0 |
| repo a–d | `oklch(0.72 0.09 {25,145,265,320})` | repo identity dots |

Type scale (px): 9.5 caps-labels · 10.5 status/meta · 11 rail/sidebar · 11.5 tabs · 12 terminal · 13.5 doc body · 14.5 doc h2 · 21 doc h1. Radii: 4 (kbd) · 5–7 (chips, icons) · 9–10 (tiles, window) · 12 (cards/palette) · 999 (pill). Doc body: sans 13.5/1.75, headings SF 650/600 weight; `tm-changed` = 2px cyan left border + horizontal gradient tint.

Repo color assignment: stable hash of repo name → 4-hue palette (same L/C in oklch); collision acceptable.

## Accepted tradeoffs / open items

- Drag = swap only in prototype; edge-split designed but unbuilt.
- In-tile terminal splits designed (v3 canvas 02) but not in prototype.
- Doc rendering assumed webview for v1 (this CSS ports directly); native renderer can adopt the same tokens later.
- Bell as the only "needs you" signal depends on tools emitting BEL; claude code does, others may not — revisit if it proves insufficient.

## Milestones (suggested)

- **M0 walking skeleton**: window + one terminal (libghostty or SwiftTerm) + `tarmac open <path>` over unix socket → peek renders markdown + FSEvents live-reload. *Acceptance: can do real work with claude code inside it.*
- **M1 doc states**: dock/index, pin tiles, drag-swap, provenance dots + pulses.
- **M2 honest signals**: foreground-process tab labels, bell detection, exit toasts, processes + file-events rail.
- **M3 strips**: session persistence (daemon-owned ptys; tmux `-CC` as opt-in interop), restore card, ⌘K switcher, per-strip layout persistence.

## Implementation decisions (v1 build)

These resolve the stack/architecture questions left to "the implementer." The **design is unchanged** — tokens, states, and choreography stand; this is only *how* it gets built.

**Stack: Swift shell + Rust core as a standalone daemon.** Native AppKit/SwiftUI for the window and all chrome; a Rust daemon (`tarmacd`) for everything systemsy. *Rejected:* web-first (Tauri/Electron) — sacrifices native terminal latency in a terminal-first tool; all-Rust/GPUI — young framework, and would force native doc rendering (no direct WKWebView reuse).

**The boundary — "`tarmacd` = observatory + ptys; the app = cockpit glass."** The daemon *observes OS facts and owns processes*; the app *renders facts and takes human input*. One rule for state: **the daemon is source-of-truth for anything that must survive a restart or is an observed OS fact; the app is source-of-truth for live, in-the-moment view state.**

| Concern | Owner |
|---|---|
| window, chrome, visual design, animation, drag, keyboard | Swift app |
| terminal rendering (grid → pixels) | Swift app (`TerminalSurface`) |
| doc content rendering | Swift app (WKWebView — design CSS ports directly) |
| pty spawn + master-fd ownership | `tarmacd` |
| foreground process (`tcgetpgrp`), elapsed, exit code | `tarmacd` |
| BEL detection (reads the pty byte stream) | `tarmacd` |
| FSEvents / file-change log | `tarmacd` |
| `tarmac` CLI socket server | `tarmacd` |
| repo-color hash, doc registry, provenance (cli vs user) | `tarmacd` |
| durable session state (strips, dock list, layout, lastChangedAt) + disk | `tarmacd` |
| live view state (drag-in-progress, peek-width drag, focus, toast queue) | Swift app |

Why a separate daemon (not an in-process lib): it keeps `tarmac open` alive independent of the UI, centralizes every honest signal at the point it's observed, and makes session persistence near-free (the daemon holds the pty; the UI can quit and reconnect). Extracting a daemon *later* is a costly refactor — so the boundary is drawn now, with M0's daemon kept deliberately dumb.

**Terminal: `TerminalSurface` protocol — SwiftTerm now, libghostty the target.** The terminal view is swappable behind a protocol (view + feed/input + resize + a high-level signal stream: `bell` / `title` / `cwd` / `foreground` / `exit`). M0 ships **SwiftTerm** as a *fed-surface*: the daemon reads the pty and feeds bytes in — full fidelity, no double-parse. **libghostty** (GPU, best-in-class VT) is the intended upgrade and lives entirely on the Swift side (C API, no Rust involvement). The decisive fork is *who owns the pty*:
- **fed-surface** (SwiftTerm): `tarmacd` owns + reads the pty → daemon stays the single source of signals, persistence is free.
- **self-owned** (libghostty as-is): the engine owns the pty/read/render → daemon shrinks (FSEvents + socket + state only), signals come from the engine's callbacks, terminal persistence needs tmux.

**Resolved (investigated 2026-06): libghostty has split, and the two halves force the choice — there is no mode that gives both Ghostty's GPU renderer *and* a daemon-owned pty.**
- **Full surface** (`ghostty_surface_t` — the GPU/Metal renderer the macOS app uses): its IO backend `termio.Exec` opens its *own* pty (`Pty.open`) and spawns its *own* child. The config exposes `command` (what to spawn) but **no external-fd path** — confirmed in `src/termio/Exec.zig`, and no project in the ecosystem feeds it an external pty. → **self-owned.** Persistence for these panes needs tmux, *or* a relay-shim (point ghostty's `command` at a thin client that pipes a daemon-owned process — byte relay, no double VT-parse). Its C API is **public alpha, in flux** — a tagged-stable release is estimated ~late 2026.
- **libghostty-vt** (terminal model only — VT parse + grid + reflow + scrollback; zero-dependency; **no renderer, no pty**): you own the pty (daemon ✓) and `vt_write(bytes)` into it, but **you supply the renderer.** This is the fed path — Ghostty-grade VT *without* Ghostty's renderer (≈ a better `alacritty_terminal`; Rust/Node/Go/Dart/.NET bindings already exist). An experimental binary **snapshot** API (`snapshotExport`/`snapshotImport`) targets exactly lossless detach/reattach.

So the ghostty "dream" is one of: **(a)** its real GPU renderer → self-owned + tmux/relay persistence + wait for the C API to stabilize; or **(b)** its VT model fed inside the daemon → daemon-owned + free persistence, but render it yourself. M0's SwiftTerm already gives *fed + a bundled renderer*, so libghostty-vt only earns its place if SwiftTerm's VT fidelity proves limiting.

**Persistence: daemon-owned ptys (primary); tmux control-mode (`tmux -CC`) opt-in (M3).** Because `tarmacd` already owns the ptys, "close the window → processes survive → reopen → restore the desk" comes for free with full rendering fidelity. tmux is the *fallback/interop* path (lets the user `tmux attach` from any terminal, SSH-resilient) but it double-parses VT — capping any ghostty fidelity edge for tmux-backed panes — so it's opt-in, not the substrate. M0–M2 use plain ptys, no tmux. The detach empty-state stays `tarmac`-branded (`$ tarmac attach <name>`) regardless of backend.

**Agent integration: CLI + socket is canonical; teach the agent via skill/CLAUDE.md; NOT MCP.** `tarmac open` over the unix socket is load-bearing for the no-harness philosophy — the cyan dot *means* "someone ran `tarmac open`," and **anything** (agent, user, Makefile, git hook, CI) can ring that doorbell. MCP would re-couple the app to one agent runtime, break that universality, and blur the signal's single source. Discovery/proactive use is taught with a one-line CLAUDE.md convention (installable on first run) plus `tarmac --help` and the cold-start hint — not a live tool channel. A thin MCP *shim over the same CLI* is possible later but deferred. `tarmac` itself is a small static Rust binary; verbs stay minimal and fire-and-forget: `open <path>` · `focus <path>` · `attach <strip>`.

**IPC: length-prefixed msgpack over one unix socket.** Two client kinds, distinguished by a hello frame:
- **CLI** (short-lived, request/ack): `Open{path}` · `Focus{path}` · `Attach{strip}` → `Ack`/`Err`; the daemon also pushes `DocOpened` to the connected app.
- **App** (long-lived, bidirectional, multiplexed by `termId`): app→ `SpawnTerminal` · `Input` · `Resize` · `LayoutChanged` · `Attach`/`Detach`; daemon→ `Restore{strips,docs,layout}` (on connect) · `Output{termId,bytes}` · `Signal{termId, bell|title|cwd|fg|exit}` · `FileEvent` · `DocOpened` · `ProcessEvent`.

The Swift↔Rust bridge is therefore this **wire protocol**, not in-process FFI; UniFFI is optional (only to wrap the protocol in a typed Swift client lib). The daemon *forwards* terminal bytes over the socket rather than fd-passing (SCM_RIGHTS) — simpler, and terminal bandwidth is trivial for a unix socket; revisit only if latency demands it.

**Rendering split:** chrome = native AppKit/SwiftUI; doc *content* = WKWebView (the design's doc CSS ports directly — recovered by choosing a Swift shell over GPUI); terminal = `TerminalSurface`. Three renderers, each in its sweet spot.

**Maps to milestones:** M0 = `tarmacd` spawns one pty + SwiftTerm fed-surface + `tarmac open` over socket → WKWebView peek + FSEvents live-reload. Persistence/tmux land in M3 per above.

## Files

- `Tarmac — Interactive Prototype.html` + `tarmac-proto/` — working prototype (behavioral spec): `app.jsx` state/keyboard/sim wiring, `desk.jsx` drag-swap, `panels.jsx` dock/index/rail/peek/switcher, `term.jsx` terminal rendering, `data.jsx` fixtures, `proto.css` interaction styles.
- `Tarmac Cockpit — v3 No-harness.html` + `tarmac/` — final static screens incl. signal-anatomy board; `theme.css` is the canonical token sheet, `converged.css` layout components.
- `Tarmac — Cold Start Flow.html` — onboarding sequence + rules.
- Earlier explorations (v1/v2) included for decision history only.

Open any HTML file in a browser; canvases support pan/zoom and per-artboard fullscreen.
