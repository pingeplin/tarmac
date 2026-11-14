# Tarmac wire protocol — v1 (M0 + M1 subsets)

> **Doc status: ACTIVE** — normative, and gated by the conformance vectors at
> the bottom. If this page and the code disagree, one of them is a bug. Docs
> index: [`README.md`](README.md).

Authoritative contract between `tarmacd` (Rust daemon), the `tarmac` CLI, and the
macOS app. Both sides implement exactly this; the conformance vectors at the bottom
are mandatory tests in both codecs — Rust
(`core/crates/tarmac-protocol/src/tests.rs`) and Swift
(`app/Tests/TarmacKitTests/ConformanceTests.swift`). Unknown message *types*
received by any party are ignored (log and continue), not fatal.

The *M1 subset* section below is purely additive to M0: new optional keys on
existing messages and new app→daemon types. The version stays `v:1`; M0 parties
remain correct under the mandatory ignore-unknown rules.

## Transport

Unix stream socket, resolved identically by daemon, CLI, and app **per build
channel** (the channel is each binary's own build configuration).

- Default path, release build: `~/Library/Application Support/tarmac/tarmacd.sock`
  (unchanged — existing users are never migrated).
- Default path, debug build: `~/Library/Application Support/tarmac/dev/tarmacd.sock`
  — keeps a `make run` dev build isolated from the installed release app. `state.json`
  sits beside the socket under the same per-channel dir.
- Env override: `TARMAC_SOCKET=<path>` — honored by daemon, CLI, and app (tests/dev);
  wins verbatim in **both** channels.
- Daemon startup: create the parent directory; if the socket file already exists, try
  connecting to it — success means another daemon is alive (log and exit 1); failure
  means it is stale (unlink and bind).

## Framing

Every message is a 4-byte big-endian unsigned length `N` followed by `N` bytes of
MessagePack. Max `N` = 16 MiB; a larger frame is a protocol error (close the
connection).

## Encoding rules

- Every message is a MessagePack **map with string keys**.
- `"t"` (string) identifies the message type.
- Decoders MUST accept map keys in any order and MUST ignore unknown keys.
- Binary payloads use the msgpack **bin family** (bin8/16/32) — never arrays of ints.
- Integers use compact msgpack encodings; decoders accept any correct integer width.
- Optional fields are msgpack nil; encoders may omit them instead, and decoders treat
  a missing key as nil.

Implementation note (Rust): serde internally-tagged enums combined with byte fields
have known pitfalls; encoding via `rmpv::Value` or a hand-rolled codec is fine as
long as the rules above hold.

Implementation note (Swift): the app's codec is hand-written (`MsgPack` and
`Message` in `TarmacKit`). Beyond these rules its encoder is pinned to the bytes
the Rust encoder emits, key order included
(`app/Tests/TarmacKitTests/RustEncoderParityTests.swift`).

## Handshake

First frame from any client:

    {t:"hello", role:"cli"|"app", v:1, app_version?:"<semver>"}

Daemon replies:

    {t:"hello_ok", v:1, daemon_version?:"<semver>", daemon_pid?:<u32>,
                        app_version?:"<semver>", app_connected?:<bool>}

Every key but `v` is OPTIONAL (`skip_serializing_if = None`); a missing key
decodes to nil. Unsupported version or role: `{t:"err", msg:"..."}` then close.

| key | on | missing ⇒ | semantics |
|---|---|---|---|
| `app_version` | `hello` | the client named no version | the app's own version: the `CARGO_PKG_VERSION` of the daemon it ships with, stamped into its bundle. Only an `app` sets it; a `cli` client MUST NOT. |
| `daemon_version` | `hello_ok` | daemon version-unverified | the daemon's `CARGO_PKG_VERSION`. |
| `daemon_pid` | `hello_ok` | pid unknown | the daemon's OS pid, so the app can SIGTERM a stale daemon it did not spawn. |
| `app_version` | `hello_ok` | the app named no version, or no app is connected — `app_connected` disambiguates | the version the currently-connected app reported in its `hello`. |
| `app_connected` | `hello_ok` | **the daemon predates this key** — NOT "no app" | whether an app holds the daemon's app slot right now. |

`app_version` and `app_connected` are sent to `cli` clients only; to an `app`
client the daemon sends neither. Telling a connecting app that no app is
connected would be false while its predecessor still holds the slot, and the
daemon reports observed facts or nothing.

The two `hello_ok` app keys are deliberately independent: `{app_connected:true,
app_version:nil}` is an app that connected without naming a version, which a
reader MUST NOT render as "no app". `tarmac --version` is the consumer.

The app compares `daemon_version` against its own version on every connect. On
mismatch (or absent key) the app SIGTERMs the stale daemon, waits for the socket
file to disappear, spawns the newly-installed binary, and reconnects; a
restart-once guard prevents thrashing on persistent mismatch. An app that knows
no version of its own names none and restarts nothing.

## CLI session (short-lived)

    → {t:"open", path:"/abs/path.md"}
    ← {t:"ack"}  |  {t:"err", msg}

`tarmac push` sends `push` frames on the same session: see *Events for a loaded
HTML card*. `tarmac report` sends one `report` frame: see *A terminal's report*. `tarmac --version` also opens the socket. It completes the
handshake, renders `hello_ok`'s daemon and app keys, and closes without sending
a second frame.

- `path` MUST be absolute. The CLI makes it absolute against its working
  directory (`std::path::absolute`) and makes no file-system call on it, so a
  hung volume cannot hang it. The daemon refuses a non-absolute path,
  canonicalizes it, and owns every error text, which the CLI prints as
  `tarmac: {msg}`. On `ack` the CLI prints `opened` with the path it sent.
- v4 Phase 3 adds an OPTIONAL `term_id` to `open` (see *v4 Phase 3 additive
  keys*); the CLI sets it from `TARMAC_TERM_ID` when run inside a tarmac pty.
- The file must exist; otherwise `err`.
- Daemon effects: upsert doc-registry entry `{path, via:"cli", last_changed_ms:nil}`;
  start watching the file (see *File watching*); push `doc_opened` to the connected
  app, if any.
- The client closes after the reply.

## App session (long-lived)

M0 supports a single app connection; a newly connecting app replaces the previous
one (the old connection is closed).

Immediately after `hello_ok`, daemon sends:

    {t:"restore", docs:[{path, via:"cli"|"user", last_changed_ms:<uint ms-epoch>|nil}, ...]}

(M1 extends this message — doc entries gain keys, `docs[]` order becomes normative,
and a `tiles` key is added; see *M1 subset*.)

app → daemon:

    {t:"spawn_term", term_id, cols, rows, cwd, cmd}
        term_id : app-generated unique string (e.g. UUID)
        cols/rows : uint
        cwd : string | nil        (nil → $HOME)
        cmd : [string, ...] | nil (nil → user's login shell: $SHELL else /bin/zsh, args: -il)
        pty env: TERM=xterm-256color, rest inherited
    {t:"input", term_id, bytes:<bin>, typed?:true}   — `typed`: see A terminal's report
    {t:"resize", term_id, cols, rows}
    {t:"open", path}    — same effects as CLI open but via:"user"; no reply frame;
                          doc_opened is still pushed (single code path)
                          (v4 Phase 3 adds an optional `term_id`; see below)

daemon → app:

    {t:"output", term_id, bytes:<bin>}      — raw pty bytes, read order, chunks ≤ 64 KiB
    {t:"exit", term_id, code:<int>|nil}     — child exited (nil = killed by signal);
                                              the term's resources are gone after this
    {t:"doc_opened", path, via:"cli"|"user"}  — M1 adds the rest of the doc entry; see M1 subset
    {t:"file_event", path, mtime_ms:<uint>} — see File watching
    {t:"doc_event", path, data}             — see Events for a loaded HTML card
    {t:"term_report", term_id, ...}         — see A terminal's report
    {t:"err", msg}                          — non-fatal notice

## File watching semantics

Watch the doc's **parent directory** (non-recursive) — editors and agents replace
files atomically, so watching the file inode directly misses rewrites. A data file
in a directory under the doc's own has that directory watched too (see Naming a
doc's data file). An event of
the watcher only wakes the daemon. The daemon then stats each doc of the active
board, and each data file that one of them reads (`data_file`), and sends a
`file_event` for each file that differs — in mtime, length or
inode — from what the daemon last saw for that board and doc. So `mtime_ms` can be
the one of the `file_event` before. From the watcher: at most one `file_event` for
a doc per 100 ms. If the file is deleted, stop emitting until the path exists again
(M0 has no doc_removed message).

A `file_event` is sent for a doc of the **active** board only. A change made while
the doc's board is in the background is reported when that board becomes active:
its `restore` carries the new `last_changed_ms`, and a `file_event` for the doc
follows the `restore` (#256). Each board has its own record, so a doc on two boards
is reported to each.

A change of a doc of the active board made while no app is connected is recorded
and saved like any change, and held: the app that connects gets it in the
`restore`, with a `file_event` after. After a daemon restart the `restore` still
carries it and no `file_event` follows. For a doc of a board in the background
nothing is recorded before the board is shown, so a daemon restart before that
loses the change. A change made while the daemon is not running is not reported.

## M1 subset (doc states & layout)

Everything here follows the M0 encoding rules: maps with string keys, `"t"` tag,
unknown types/keys ignored, optional = nil-or-omitted, missing key = nil.

### Doc entry

One map shape, used in two places: nested in `restore.docs[]`, and flattened into
`doc_opened` (entry keys at top level beside `"t"`). M0 senders omit the new keys;
decoders apply the defaults below, so every M0 frame still decodes.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `path` | string (required) | — | canonical absolute path; registry key |
| `via` | `"cli"`\|`"user"` (required) | — | most recent opener |
| `repo` | string \| nil | nil | repo display name = basename of `repo_root`; nil when the doc is not inside a git repo (the app then falls back to the parent directory's basename, exactly as in M0) |
| `repo_root` | string \| nil | nil | absolute path of the enclosing git repo root; the grouping identity — two distinct repos both named `api` group separately |
| `repo_color` | uint 0–3 \| nil | nil | daemon-computed palette index (algorithm below); nil iff `repo` is nil (the app then shows no repo dot) |
| `read` | bool | true | false ⇔ unread (a cli open clears it; `doc_read` sets it). Not an optional: M1 encoders always write true/false, never nil; a missing key means true so entries from M0-era daemons never render an unread dot |
| `last_changed_ms` | uint \| nil | nil | unchanged from M0: mtime_ms of the last observed file change |
| `last_opened_ms` | uint \| nil | nil | wall-clock ms-epoch of the most recent open (cli or user); M1 daemons always send it (registration is an open) |
| `term_id` | string \| nil | nil | **v4 Phase 3, additive**: the term that opened the doc (provenance + gravity owner). The daemon sets it from the `open` message's `term_id` (the CLI reads `TARMAC_TERM_ID` from its pty env); a re-open carrying a `term_id` updates the owner, one without leaves it. Persisted; carried in both `restore.docs[]` and `doc_opened` |

#### `repo_color` algorithm

FNV-1a 64-bit over the UTF-8 bytes of `repo`, then mod 4:

    hash = 0xcbf29ce484222325                       # offset basis
    for each byte b of repo's UTF-8 encoding:
        hash = (hash XOR b) * 0x100000001b3         # wrapping 64-bit multiply
    repo_color = hash mod 4                         # 0=repo-a 1=repo-b 2=repo-c 3=repo-d

The app hashes nothing: it maps this index onto its four-colour palette, so the
algorithm must not change — colors users already saw would move. (Reference
values: `payments-api`→3, `search-svc`→2, `infra`→1.)

### Tile

The desk layout element, used in `restore.tiles[]` and `layout.tiles[]`:

    {kind:"term"}                  — the terminal tile's slot
    {kind:"doc", path:<string>}    — a pinned doc, by registry path

`kind` is required. Receivers MUST skip a tile whose `kind` they do not recognize
(drop the tile, keep the rest) and MUST ignore unknown keys inside a tile — M2+ adds
its own keys (`term_id`, splits, per-strip arrays) under this rule.

### `restore` (extended)

    {t:"restore", docs:[<doc entry>, ...], tiles:[<tile>, ...]}

- `docs[]` order is now normative: it **is** the dock order (insertion order — M0
  left HashMap order undefined).
- `tiles[]` is the persisted desk tile order, in slot order. M1 daemons always
  include exactly one `{kind:"term"}` tile. A missing or empty `tiles` means
  `[{kind:"term"}]` (terminal only).

A daemon restart followed by an app connect MUST produce a `restore`
indistinguishable from one without the restart (registry + dock order + tile order
are persisted to disk).

### `doc_opened` (extended)

    {t:"doc_opened", path, via, repo, repo_root, repo_color, read,
     last_changed_ms, last_opened_ms}

Carries the full doc entry so the app can render the unread dot, repo dot color, and
dock/index rows for a brand-new doc without a round-trip. The daemon upserts the
registry *before* pushing, so the entry already reflects the post-open state (a cli
open arrives as `via:"cli", read:false` with a fresh `last_opened_ms`).

### app → daemon (new; fire-and-forget, no reply frame)

    {t:"doc_read", path}

Sets the doc's `read := true`. Idempotent — a sender may repeat it freely. A path
not in the registry is ignored.

    {t:"layout", dock:[<path>, ...], tiles:[<tile>, ...]}

Full layout snapshot, last-writer-wins; the app sends it after every committed pin,
unpin, and tile swap. `dock` is the complete dock order even though no M1 gesture
reorders the dock (shape stability for later dock drag). Daemon merge rules: paths
not in the registry are ignored; registered docs missing from `dock` keep their
previous relative order, appended at the end (so an open racing a snapshot converges
on insertion order).

## v4 board additive keys

The v4 "whiteboard" model (docs/archive/v4/migration-plan.md Phase 2; docs/archive/v4/visual-crib.md
§9) makes each strip an infinite canvas: cards carry a world-space frame and the
viewport (pan + zoom) is persisted. These are **additive** under the M0 encoding
rules — new OPTIONAL keys, missing ⇒ nil, unknown keys still ignored — so all 7
vectors above and every M1 frame decode unchanged (a tile with no geometry and a
`layout`/`restore` with no `board` are exactly the M1 shapes).

### Tile (extended)

The tile gains an optional world-space card frame and stacking order. `kind` stays
required; `path` and the new keys are all optional (missing ⇒ nil). Receivers still
skip unknown `kind`s and ignore unknown keys.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `kind` | string (required) | — | `"term"` \| `"doc"` (unrecognized ⇒ skip the tile) |
| `path` | string \| nil | nil | registry path (doc tiles) |
| `x` | float \| nil | nil | world-space left |
| `y` | float \| nil | nil | world-space top |
| `w` | float \| nil | nil | world-space width |
| `h` | float \| nil | nil | world-space height |
| `z` | int \| nil | nil | stacking order (z-index) |
| `term_id` | string \| nil | nil | **v4 Phase 5b, additive**: the terminal tile this card belongs to. The board holds N terminal cards (one per pty), each persisting its own position; the daemon keys them by `term_id`. Absent on doc tiles and on legacy single-terminal layouts |

A tile without `x/y/w/h/z` behaves exactly as an M1 tile (the app falls back to grid
placement).

**v4 Phase 5b — multiple terminal tiles.** A `layout`/`restore` may carry more than
one `{kind:"term"}` tile, each with a distinct `term_id` (e.g. `{kind:"term", x, y,
w, h, z, term_id}`). `Registry::set_tiles` keeps every terminal tile with a distinct
`term_id`; a `term_id`-less term tile is the legacy single-terminal slot, kept once;
a duplicate `term_id` is dropped. An empty / term-less layout still gets one default
`{kind:"term"}` tile, so the board is never term-less. The wire is byte-identical to
pre-5b when no `term_id` is present (additive guarantee). On restart the daemon's ptys
are gone, so the app respawns fresh shells into the persisted positions (live-session
restore is a later milestone); doc provenance re-anchors best-effort.

### `board` viewport

`restore` and `layout` gain an optional `board` map — the persisted viewport for the
strip. The whole map is optional (missing ⇒ nil ⇒ the app uses a default viewport):

    {t:"restore", docs:[...], tiles:[...], board:{zoom, cx, cy}}
    {t:"layout",  dock:[...], tiles:[...], board:{zoom, cx, cy}}

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `board.zoom` | float | — (required if `board` present) | viewport zoom factor |
| `board.cx` | float | — (required if `board` present) | viewport center x (world) |
| `board.cy` | float | — (required if `board` present) | viewport center y (world) |

Daemon behavior: the registry stores the per-strip viewport alongside the tiles;
`persist.rs` round-trips `x,y,w,h,z` (carried on the persisted tiles) and `board`
(`PersistedState` gains an optional `board`; `PersistedDoc` is unchanged). On a
`layout`, `board` is last-writer-wins: a snapshot carrying one replaces the stored
viewport, a snapshot omitting it leaves the stored viewport untouched. A daemon
restart followed by an app connect MUST reproduce the same frames + viewport in
`restore` (the existing restart-indistinguishability invariant, extended to the new
keys).

## v4 Phase 3 additive keys

Phase 3 (docs/archive/v4/migration-plan.md Phase 3; docs/archive/v4/visual-crib.md §5/§6/§8)
adds placement semantics — gravity, the shelf, and provenance edges. As with
the board keys, these are **additive** under the M0 encoding rules: new OPTIONAL
keys, missing ⇒ nil, unknown keys still ignored. All 8 conformance vectors and
every M1 frame decode unchanged.

### Tile (extended again)

The tile gains two optional flags. A tile without them behaves exactly as a
Phase-2 tile (attached, on the board).

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `loose` | bool \| nil | nil (⇒ attached) | gravity-detached flag: `true` ⇒ the user has moved this doc card, so it no longer follows its owner term card |
| `shelf` | bool \| nil | nil (⇒ on board) | `true` ⇒ the doc is parked on the shelf rather than placed on the board. A shelf doc tile is `{kind:"doc", path, shelf:true}` with **no** `x/y/w/h` (and typically `loose:true`); `set_tiles` keeps it because it is a known-path doc tile, geometry or not |

### `open` (extended)

    {t:"open", path, term_id}

`term_id` (string \| nil; missing ⇒ nil) is the term that ran the open. The CLI
reads it from the `TARMAC_TERM_ID` env var, which the daemon sets in every pty
it spawns (`builder.env("TARMAC_TERM_ID", &term_id)`), so a `tarmac open` run
inside a tarmac terminal attributes itself to that terminal card. The app's own
`open` arm passes `term_id` (or nil). The daemon stores it on the doc registry
entry and surfaces it via the doc entry's `term_id` (above) in `doc_opened` and
`restore`. `persist.rs` round-trips it (`PersistedDoc.term_id`, serde default).

### Doc entry (extended)

The doc entry's `term_id` (documented in the *Doc entry* table above) is the
provenance owner — it rides on both `restore.docs[]` and `doc_opened`. The shelf
membership and `loose` flag ride on the persisted **tiles**, not the doc entry,
so there is no extra persist change for them beyond the tile keys.

## M2 honest signals

Phase 3.5 (docs/archive/v4/migration-plan.md Phase 3.5) surfaces the real terminal
signals the wayfinding chrome is built around — foreground process name, the
terminal bell, and exit. These are **new additive daemon→app message TYPES**, not
new keys on existing messages: a receiver that does not recognize them ignores
them under the unknown-type rule, so all 8 conformance vectors and every M1/v4
frame decode unchanged. They carry no state through persist — they are live
notifications about a running pty.

    {t:"term_proc", term_id, name, pid:<int>|nil}   — daemon → app

The current foreground process name on a terminal (the basename of the
process-group leader's argv[0], less a login shell's leading `-`). The daemon
polls the pty's controlling process group (`tcgetpgrp` via
`MasterPty::process_group_leader`) and reads argv[0] (`sysctl(KERN_PROCARGS2)`
on macOS), or, when argv is unreadable, the executable path (`proc_pidpath`);
it pushes a `term_proc` only when
the name **changes** (deduped; pushed once on the first resolve). The app sets
the term card's header label to `name` (the honest "card title = process name").

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal whose foreground process this is |
| `name` | string (required) | — | foreground process name (executable basename) |
| `pid` | int \| nil | nil | the process-group leader pid, when resolvable (diagnostic) |

    {t:"bell", term_id}                              — daemon → app

A BEL byte (`0x07`) outside an escape string was seen in the terminal's output
stream. The daemon scans forwarded output chunks for such a `0x07` and pushes
`bell` debounced to at most one per ~250 ms. A BEL that ends an OSC, or one
inside a DCS, SOS, PM or APC payload, is not a bell. The app gives the term card
an amber (`#fdbc4b`) signal that clears on the next keystroke to that terminal
or when it regains focus.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal that rang the bell |

## M3 boards ("strips = boards")

Five additive message types. A receiver that does not know them ignores them
under the unknown-type rule, so every pre-M3 vector decodes unchanged.

    {t:"board_list", boards:[<board meta>, ...], active}   — daemon → app
    {t:"board_switch", board_id}                           — app → daemon
    {t:"board_create"}                                     — app → daemon
    {t:"board_rename", board_id, name}                     — app → daemon
    {t:"board_delete", board_id}                           — app → daemon

`board_list` is pushed right after `hello_ok` and again on every board change
(create / rename / delete / switch, and terminal spawn+exit, which move the
`running` count). `board_switch` makes a board active and the daemon replies with
that board's `restore`. `board_create` mints a board — the **daemon** assigns the
slug id, so there is no id on the request. `board_rename` with an empty `name`
clears the name back to the slug fallback. `board_delete` kills the board's ptys
and is a **no-op when it targets the last board**; if the deleted board was
active, the daemon fixes `active` and sends the new active board's `restore`.

### Board meta

    {board_id, name?, running?}

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `board_id` | string (required) | — | stable slug (`board-0`, `board-1`, …); display order is the array order, which backs `⌘1`–`9` |
| `name` | string | unnamed | user-given display name; the app falls back to `board_id` |
| `running` | uint | unknown | terminals on that board with a live pty — one of the two honest session signals |

### Additive `board_id` keys on existing messages

M3 scopes the pre-existing messages per board. Every one is optional with a
missing⇒default decode, so a single-board sender that never sets them keeps the
byte-identical wire:

| message | key | missing ⇒ |
|---|---|---|
| `open` | `board_id` | the calling term's board, else the active board |
| `layout` | `board_id` | the active board |
| `spawn_term` | `board_id` | `board-0` / active |
| `restore` | `board_id` | `board-0` — the daemon always stamps it so the app can bind a restore unambiguously across rapid switches |

### `restore.live_terms` (P5)

    {t:"restore", ..., live_terms:[term_id, ...]}

The term_ids the daemon currently owns a **live** pty for on the restored board.
The app re-binds those cards to the running shells instead of cold-spawning.
Their history comes from a `scrollback` reply; the `output` replay that follows
the restore is held and discarded in its favour.
Missing or empty means cold-spawn: the pre-P5 behaviour, and the daemon-restart
case where the shells really are gone. This is what makes an app reconnect
survive with live terminals while a daemon restart does not.

### `spawn_term.inherit_cwd_from` (issue #77)

    {t:"spawn_term", ..., inherit_cwd_from:"t1"}

Start the new pty in the **live** cwd of another terminal (⌘T inheriting the
prime terminal's current directory), resolved daemon-side at spawn time so it
reflects where that shell is *now*, including after it has `cd`'d away. Ignored
when `cwd` is already set; an unknown or dead source term falls through to the
normal default.

## A terminal's last folder (issue #345, spec 2611.0007)

    TermRecord      {last_cwd?: str}                            — a map, string keys
    {t:"restore", ..., term_records:{<term_id>: TermRecord}}     — daemon → app
    {t:"spawn_term", ..., succeeds:"t0"}                         — app → daemon

Each board keeps a table `term_records`: what the daemon keeps of one terminal
across its restarts. It is persisted in `state.json` beside the board's
`tiles`, and a `layout` never changes it.

- **Recording.** The daemon reads a terminal's cwd when its foreground pid
  changes (and once for the first pid), and once more at a shutdown by SIGTERM,
  SIGHUP or SIGINT, before the socket goes. A read that does not answer keeps the
  value before it. A cwd read never saves the state by itself.
- **Deleting.** A `term_close` deletes the record, whether the term is live or
  not, on whichever board holds it. A clean exit (`code: 0`) deletes it too; a
  non-zero or signal exit keeps it, for the card held dead. A deleted board takes
  its table with it. A read that returns after the record is gone does not make
  it again.
- **`succeeds`.** A cold spawn of a persisted tile names the persisted id. When
  the spawn succeeds, the daemon moves that id's record, on the new term's own
  board only, to the new `term_id`. It is ignored — never an error — when it
  names a live term or an id with no record there, or when the spawn fails.
- **Restore.** The app's first-visit restore of a board sends a cold spawn of
  each persisted tile with `cwd: last_cwd` and `succeeds: <persisted id>`. The
  daemon checks `cwd` as for any spawn: a folder that is gone gives `$HOME`.

A live terminal has a record before its first read, which may have no
`last_cwd`.

| message | key | type | missing ⇒ |
|---|---|---|---|
| `restore` | `term_records` | map of term id → `TermRecord` | an empty table; omitted when empty |
| `spawn_term` | `succeeds` | string | nil; omitted when nil |
| `TermRecord` | `last_cwd` | string | nil; omitted when nil (a record with none is an empty map) |

`spawn_term.cwd` and `cmd` keep their encoding: a nil is written as msgpack nil.

## Closing a single terminal (issue #15)

    {t:"term_close", term_id}                       — app → daemon

Terminate one terminal's pty so ⌘W can close a single terminal card. The daemon
SIGHUPs the term's process group (reusing the board-delete kill path); the pump's
wait thread then runs the normal teardown and pushes the usual `exit`. It also
deletes the term's record (`term_records`, issue #345), live or not. A
`term_close` for a `term_id` with no pty kills nothing. New **additive app→daemon
type**: a receiver that does not know it ignores it under the unknown-type rule,
so all existing vectors decode unchanged.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal whose pty to terminate |

## Refreshing a doc on demand (issue #89)

    {t:"doc_refresh", path}                         — app → daemon

Re-stat a doc now and push the usual `file_event`, so a doc card can be refreshed
without waiting for the watcher. This is the fallback for a change that the daemon
has not seen yet: an event of the watcher can be late or lost.

The daemon stats the file and, if the path is a doc on the active board, records the
real mtime in the registry (before pushing, as the watcher does) and pushes
`file_event`. It **always** pushes on a successful stat, changed mtime or not — "did
anything change" is answered by the receiver comparing values, which is what keeps a
refresh of an unchanged file from reloading an HTML card. A `doc_refresh` for an
unknown path, for a doc on a non-active board, or for a file that cannot be stat'd
(deleted, unreadable) is a silent no-op: no push, no `err`. `path` must be the
registry key — the daemon does not canonicalize it here. New **additive app→daemon
type**: a receiver that does not know it ignores it under the unknown-type rule, so
all existing vectors decode unchanged.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `path` | string (required) | — | the doc to re-stat (the registry key) |

## Naming a doc's data file (issue #311)

    {t:"data_file", board_id, path, file}           — app → daemon
    {t:"data_file", board_id, path}                 — app → daemon: the doc reads none

An HTML doc names one JSON file in its own directory or in a directory under it,
at any depth (2611.0005), its **data file**; the app reads that
file and hands its content to the loaded document. The daemon reports the data
file as it reports a doc: with a `file_event {path: <file>, mtime_ms}`. There is no
reply frame.

The daemon records `file` with the doc entry of `path` on board `board_id`. A
`data_file` with a `file` replaces the doc's data file; one with no `file` clears
it. It is in memory only: never in the state file, and gone when the doc is
closed or its board deleted, and every registration of every board is dropped
when the app's connection ends or another connection takes its place: the app
names each file again after it connects. It is ignored, with nothing recorded and
the registration before kept, for an unknown `board_id` (there is **no**
fall-back to the active board), for a `path` that is not a doc of that board, and
for a `file` that is not a file under the doc's directory: relative, outside that
directory, with a `.`, `..` or empty component (`//`), ending in `/`, naming no
file (`<dir>`), or with a **hidden** component (one that starts with `.`) below
the doc's directory. The path is judged on its bytes as given, with no link
followed and nothing worked out, so `<dir>/sub/../x.json` and `<dir>/./x.json`
are refused; the doc's own directory may be hidden.

- **At once.** When the board is the active one and the file is there, the daemon
  takes the file as seen and pushes a `file_event` for `file`, for every
  `data_file` that names it, the same name again included. A file that is not
  there pushes nothing.
- **Then, for each change.** The data files of the active board are compared in
  each look, as its docs are (see File watching): a file that differs from what
  was seen for that path on that board — in mtime, length or inode — gets a
  `file_event`. A file that is gone pushes nothing and is a change when it is
  back. One change of a path gives one `file_event`, also when two docs name it
  or when it is a doc of the board too.
- **The watch.** A file beside the doc needs no watch of its own: the doc's
  directory is watched. For a file in a directory under it, the daemon resolves
  that directory (links followed) and counts and watches the resolved directory,
  as it does a doc's, for as long as the registration stands; the same name again
  counts nothing more. A directory that resolves to the doc's own, out of the
  doc's tree, or to a hidden name below it is not watched: each look still stats
  the file. A directory that is not there, or cannot be watched, is tried again at
  each change that the file system reports and at each `data_file` that names the
  file again. A board in the background counts its watch too.
- **A board in the background** is not answered at once. Each `data_file` with a
  `file` starts from nothing seen, so when that board is made active a
  `file_event` for the data file follows its `restore`, if the file is there;
  after that, as for a doc, one follows the `restore` when the file changed.
- A data `file_event` that reaches no app is not held: the app sends `data_file`
  again after it connects, and the answer brings the content.

`doc_refresh` does not look at data files. New **additive app→daemon type**: a
daemon that does not know it ignores it under the unknown-type rule, and the card
gets no data; all existing vectors decode unchanged.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `board_id` | string (required) | — | the board of the doc; an unknown id is ignored |
| `path` | string (required) | — | the doc that reads the file (the registry key) |
| `file` | string | the doc reads no data file | absolute path of the data file, in the doc's directory or under it |

## Events for a loaded HTML card (issue #326)

    {t:"push", path, value}         — cli → daemon; answered with ack | err
    {t:"doc_event", path, value}    — daemon → app; no reply

`tarmac push` gives one JSON value to the HTML cards of an open doc that are
loaded at that moment. `value` is the value as text. The daemon checks it, the
app does not parse it, and the document gets it as a `tarmac:push`. A cli
session can carry any number of `push` frames. The cli sends each one after the
answer to the one before, because an answer carries no id.

The daemon checks a `push` in this order. The first check that fails is the
answer, `err {msg}`; `<path>` is the path as given:

| Case | Answer |
| --- | --- |
| the frame does not decode (no `path` or no `value`, or a `value` that is not a msgpack str) | `err "malformed frame: <decoder's message>"`, as for any frame of the session; the connection stays open |
| `value` is not one JSON value (below) | `err "not one JSON value: <serde_json's message>"` |
| `path` is not absolute | `err "path is not absolute: <path>"` |
| the resolve fails | the text `open` answers: `cannot open <path>: <io error>`, `cannot stat <resolved>: <io error>`, or `not a regular file: <resolved>` |
| the resolve does not answer in the path gate's limit | `cannot open <path>: did not answer in <limit>`, as `open` answers |
| no board has the doc | `err "not an open doc: <path>"` |
| the `doc_event` would be over `MAX_FRAME_LEN` | `err "value is over the frame limit (16 MiB)"`; nothing is pushed |
| no app is connected | `err "no app is connected"` |
| otherwise | `ack`, after the `doc_event` is queued for the app |

- **The path.** The daemon looks `path` up as a doc key on every board. When no
  board has it as given, it resolves it as `open` does (canonicalized, a regular
  file, through the time-limited path gate) and looks up the resolved path. Each
  cli connection keeps the resolved path of each path it gave whose resolve
  succeeded, and does not resolve that path again; a resolve that failed is made
  again on the next `push`. The registry is asked on every `push`, so a doc
  closed since is refused.
- **One `doc_event` for each `push`**, however many boards hold the doc. Its
  `path` is the registry key (the resolved path) and its `value` is the `push`'s,
  byte for byte. A doc of any kind gets it, also on a board in the background:
  the app gives it only to an HTML card whose document is ready for its current
  load, and drops it otherwise. Nothing is kept for later.
- **`ack` means queued for the app**, not drawn by a card. While the app's queue
  is full, the answer waits.
- **The JSON rule** is `serde_json`'s for one value: any value at the top, white
  space (space, tab, LF, CR) around it, and nothing after it. Refused among
  others: empty text, a byte-order mark, a number out of the range of a double
  (`1e400`), an unpaired surrogate escape (`"\ud800"`), and more than 127 levels
  of nested arrays and objects.
- **The frame limit.** The cli does not send a `push` whose payload is over
  `MAX_FRAME_LEN`. A frame whose length prefix is over it ends the connection
  with no answer (*Framing*). The `doc_event` is 5 bytes longer than the `push`
  (more when the resolved path is longer), so the daemon checks it again.

A `push` on an app connection is ignored, as any message the app session does
not take. New **additive types**: a daemon that does not know `push` ignores it
under the unknown-type rule and does not answer, and the cli reports that no
answer came in 5 s. All existing vectors decode unchanged.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `path` | string (required) | — | `push`: the doc, an absolute path as given; `doc_event`: the doc's registry key |
| `value` | string (required) | — | one JSON value, as text |

## A terminal's report (spec 2611.0009)

    {t:"report", term_id, kind:"blocked"|"done"|"clear", text?}   — cli → daemon; answered with ack | err
    {t:"term_report", term_id, kind?, text?, at_ms?, proc?, read?} — daemon → app; no reply
    {t:"input", ..., typed?:true}                                  — app → daemon

A process in terminal `term_id` runs `tarmac report blocked|done ["<text>"]` or
`tarmac report clear`. The daemon keeps one current report for each live
terminal, in memory only: no key in `state.json`, so a daemon restart loses it
and an app relaunch does not.

The daemon checks a `report` in this order; the first check that fails is the
answer:

| Case | Answer |
| --- | --- |
| `term_id` is not a live terminal | `err "unknown terminal: <term_id>"` |
| `kind` is not `blocked`, `done` or `clear` | `err "unknown report kind: <kind>"` |
| `clear` | `ack`; a `text` is ignored; `term_report {term_id}` is pushed only when there was a report |
| no process to tie the report to (below) | `err "no process to tie the report to in <term_id>"` |
| otherwise | `ack`, after the `term_report` is queued for the app |

- **The text.** The daemon caps `text` at 280 Unicode scalar values
  (`cap_report_text`: a longer text keeps 279 and gets `…`), and stores an empty
  `text` as no text. The cli caps it the same way before it sends.
- **The holder.** The daemon reads the client's pid at accept (`LOCAL_PEEREPID`)
  and walks its parent pids up to the terminal's PTY child. A terminal spawned
  with a `cmd` has its PTY child as the holder. Else the chain member just below
  the PTY child is the holder (the agent), or the shell itself when the caller's
  parent is the shell (a report typed at the prompt). A caller that the walk
  cannot place (re-parented, gone, or a failed read) falls back to the
  terminal's foreground process-group leader; with none, the `err` above.
- **The lifetime.** Each 750 ms poll removes the report, with a `term_report`
  that has no `kind`, when its holder is gone: an agent pid that exited or was
  reused; a shell holder or leader holder once another foreground leader is
  seen. A command shorter than one tick is not seen. A terminal's exit removes
  its report with no `term_report`: the `exit` frame ends it in the app.
- **A repeat** is a new report: a new `at_ms`, unread, its holder found again.
- **Read.** An `input` with `typed: true` marks the current report read, and
  the daemon pushes it again with `read: true`. The app sets `typed` only for
  the user's own input. An `input` with no `typed` never marks it read.
- **Restore.** After each `restore` (and its `file_event`s), the daemon sends a
  `term_report` for every live terminal of that board, with no `kind` for one
  that has no report, then the scrollback replay. This is on every restore, not
  only a board's first one on a connection.

| message | key | type | missing ⇒ |
|---|---|---|---|
| `report` | `term_id` | string (required) | — |
| `report` | `kind` | string (required) | — |
| `report` | `text` | string | no text; omitted when nil |
| `term_report` | `term_id` | string (required) | — |
| `term_report` | `kind` | `"blocked"` \| `"done"` | no report; then only `term_id` is sent. A receiver treats a kind it does not know as no report |
| `term_report` | `text` | string | no text |
| `term_report` | `at_ms` | uint, ms since the epoch | always sent with a `kind` |
| `term_report` | `proc` | string | the holder's process name was not read |
| `term_report` | `read` | bool | **false** (the reverse of `DocEntry.read`); written only as `true` |
| `input` | `typed` | bool | false; written only as `true` |

New **additive types and key**: a daemon that does not know `report` ignores it
and does not answer, and the cli reports that no answer came in 5 s. An app that
does not know `term_report` ignores it. A daemon that does not know `typed`
ignores it. An `input` with `typed: false` encodes as before, byte for byte
(vector 3).

## Replaying a terminal's scrollback on demand (issue #41)

    {t:"scrollback_request", term_id}               — app → daemon
    {t:"scrollback", term_id, bytes}                — daemon → app

Re-send one terminal's scrollback ring now, so a terminal card built from
scratch — a first board visit, a fresh spawn — gets its history as one frame,
and a card that survived a reconnect can replace the history it already shows
instead of having it appended a second time. The connect-time replay (`restore`
+ `output` frames) cannot cover this: it fires at most once per board per
**connection**, and it arrives as a stream the card cannot tell from live
output.

The daemon snapshots that one term's ring and replies with **exactly one**
`scrollback` frame on the requesting connection. It **always** replies, even when
the ring is empty or the `term_id` is unknown — silence would leave the app
holding live output behind a reply that never comes. The request neither reads nor
sets the per-connection board-replay latch, so a board visited for the first time
after a request still gets its one-time `output` replay. Both are new **additive
types**: a receiver that does not know them ignores them under the unknown-type
rule, so all existing vectors decode unchanged.

`bytes` rides the msgpack **bin** family, exactly like `input`/`output`; the ring
is capped at 256 KiB, well inside the 16 MiB frame limit, so the reply is never
chunked. Receiving it is the app's single history source for that terminal: it
discards whatever it was holding for the term and writes these bytes, then
resumes live output. The app bounds that hold at 2 s: a daemon of the same version
built before this change decodes `scrollback_request` as `Unknown` and never
replies, so on the deadline the card releases what it held and degrades to
live-only output rather than staying blank.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal whose ring to re-send / the ring's owner |
| `bytes` | bin (required, `scrollback` only) | — | the ring snapshot; empty for a silent or unknown term |

## Conformance vectors

Hex of the msgpack payload only (length prefix excluded). Decoding each vector MUST
produce the structure shown, and each structure MUST survive an encode→decode
round-trip. Byte-exact encoder output is NOT required (key order may legally differ).

1. `{t:"ack"}`

       81 a1 74 a3 61 63 6b

2. `{t:"hello", role:"app", v:1}`

       83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01

3. `{t:"input", term_id:"t1", bytes:"ls\n"}` (3 payload bytes)

       83 a1 74 a5 69 6e 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31
       a5 62 79 74 65 73 c4 03 6c 73 0a

4. `{t:"resize", term_id:"t1", cols:120, rows:40}`

       84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31
       a4 63 6f 6c 73 78 a4 72 6f 77 73 28

5. `{t:"doc_read", path:"/a.md"}`

       82 a1 74 a8 64 6f 63 5f 72 65 61 64 a4 70 61 74 68 a5 2f 61 2e 6d 64

6. `{t:"layout", dock:["/a.md"], tiles:[{kind:"term"}, {kind:"doc", path:"/a.md"}]}`

       83 a1 74 a6 6c 61 79 6f 75 74
       a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64
       a5 74 69 6c 65 73 92
       81 a4 6b 69 6e 64 a4 74 65 72 6d
       82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64

7. `{t:"doc_opened", path:"/a.md", via:"cli", repo:"api", repo_color:3, read:false,
   last_opened_ms:1718000000000}` — `repo_root` and `last_changed_ms` omitted
   (missing key = nil); `repo_color` 3 = FNV-1a("api") mod 4

       87 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64
       a4 70 61 74 68 a5 2f 61 2e 6d 64
       a3 76 69 61 a3 63 6c 69
       a4 72 65 70 6f a3 61 70 69
       aa 72 65 70 6f 5f 63 6f 6c 6f 72 03
       a4 72 65 61 64 c2
       ae 6c 61 73 74 5f 6f 70 65 6e 65 64 5f 6d 73 cf 00 00 01 90 00 c7 9c 00

8. (v4 board additive keys) `{t:"layout", dock:["/a.md"], tiles:[{kind:"doc",
   path:"/a.md", x:120.0, y:80.0, w:470.0, h:330.0, z:2}], board:{zoom:0.82,
   cx:640.0, cy:360.0}}` — geometry floats are msgpack float64 (`cb`); `z` is an
   int. Decodes identically when the geometry keys / `board` are omitted (M1 shape,
   vector 6). All floats here round-trip bit-exact (IEEE-754 double on both sides).

       84 a1 74 a6 6c 61 79 6f 75 74
       a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64
       a5 74 69 6c 65 73 91
       87 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
       a1 78 cb 40 5e 00 00 00 00 00 00
       a1 79 cb 40 54 00 00 00 00 00 00
       a1 77 cb 40 7d 60 00 00 00 00 00
       a1 68 cb 40 74 a0 00 00 00 00 00
       a1 7a 02
       a5 62 6f 61 72 64 83
       a4 7a 6f 6f 6d cb 3f ea 3d 70 a3 d7 0a 3d
       a2 63 78 cb 40 84 00 00 00 00 00 00
       a2 63 79 cb 40 76 80 00 00 00 00 00

9. (issue #15) `{t:"term_close", term_id:"t1"}` — new additive app→daemon type;
   decodes by tag and round-trips; existing vectors are unaffected.

       82 a1 74 aa 74 65 72 6d 5f 63 6c 6f 73 65
       a7 74 65 72 6d 5f 69 64 a2 74 31

10. (issue #34) `{t:"doc_close", path:"/a.md"}` — new additive app→daemon type;
    decodes by tag and round-trips; existing vectors V1–V9 are unaffected.

        82 a1 74 a9 64 6f 63 5f 63 6c 6f 73 65
        a4 70 61 74 68 a5 2f 61 2e 6d 64

11. (issue #89) `{t:"doc_refresh", path:"/a.md"}` — new additive app→daemon type;
    decodes by tag and round-trips; existing vectors V1–V10 are unaffected.

        82 a1 74 ab 64 6f 63 5f 72 65 66 72 65 73 68
        a4 70 61 74 68 a5 2f 61 2e 6d 64

12. (issue #41) `{t:"scrollback_request", term_id:"t1"}` — new additive app→daemon
    type; decodes by tag and round-trips; existing vectors V1–V11 are unaffected.

        82 a1 74 b2 73 63 72 6f 6c 6c 62 61 63 6b 5f 72 65 71 75 65 73 74
        a7 74 65 72 6d 5f 69 64 a2 74 31

13. (issue #41) `{t:"scrollback", term_id:"t1", bytes:"hi\n"}` (3 payload bytes) —
    new additive daemon→app type; `bytes` is the msgpack **bin** family (`c4`), as
    in vector 3. An empty ring is the same frame with `c4 00`.

        83 a1 74 aa 73 63 72 6f 6c 6c 62 61 63 6b
        a7 74 65 72 6d 5f 69 64 a2 74 31
        a5 62 79 74 65 73 c4 03 68 69 0a

14. (issue #311) `{t:"data_file", board_id:"board-0", path:"/a/dash.html",
    file:"/a/stats.json"}` — new additive app→daemon type; decodes by tag and
    round-trips; existing vectors V1–V13 are unaffected. Keys in the order
    `rmp_serde::to_vec_named` writes them.

        84 a1 74 a9 64 61 74 61 5f 66 69 6c 65 a8 62 6f 61 72 64 5f
        69 64 a7 62 6f 61 72 64 2d 30 a4 70 61 74 68 ac 2f 61 2f 64
        61 73 68 2e 68 74 6d 6c a4 66 69 6c 65 ad 2f 61 2f 73 74 61
        74 73 2e 6a 73 6f 6e

15. (issue #311) `{t:"data_file", board_id:"board-0", path:"/a/dash.html"}` — the
    same type with no `file`: the doc reads none. `file` is omitted, not nil, so
    the map has three keys.

        83 a1 74 a9 64 61 74 61 5f 66 69 6c 65 a8 62 6f 61 72 64 5f
        69 64 a7 62 6f 61 72 64 2d 30 a4 70 61 74 68 ac 2f 61 2f 64
        61 73 68 2e 68 74 6d 6c

16. (issue #326) `{t:"push", path:"/a/dash.html", value:"{\"n\":1}"}` — new
    additive cli→daemon type; decodes by tag and round-trips; existing vectors
    V1–V15 are unaffected. Keys in the order `rmp_serde::to_vec_named` writes
    them.

        83 a1 74 a4 70 75 73 68 a4 70 61 74 68 ac 2f 61 2f 64 61 73
        68 2e 68 74 6d 6c a5 76 61 6c 75 65 a7 7b 22 6e 22 3a 31 7d

17. (issue #326) `{t:"doc_event", path:"/a/dash.html", value:"{\"n\":1}"}` — new
    additive daemon→app type, the same keys in the same order.

        83 a1 74 a9 64 6f 63 5f 65 76 65 6e 74 a4 70 61 74 68 ac 2f
        61 2f 64 61 73 68 2e 68 74 6d 6c a5 76 61 6c 75 65 a7 7b 22
        6e 22 3a 31 7d

18. (issue #345) `{t:"restore", docs:[], tiles:[], term_records:{"t1":{last_cwd:"/w"}}}`
    — the additive `term_records` key. `docs` is required and `tiles` is always
    written; `board`, `board_id` and `live_terms` are omitted. Keys in the order
    `rmp_serde::to_vec_named` writes them.

        84 a1 74 a7 72 65 73 74 6f 72 65 a4 64 6f 63 73 90 a5 74 69
        6c 65 73 90 ac 74 65 72 6d 5f 72 65 63 6f 72 64 73 81 a2 74
        31 81 a8 6c 61 73 74 5f 63 77 64 a2 2f 77

19. (issue #345) `{t:"spawn_term", term_id:"t1", cols:80, rows:24, cwd:nil, cmd:nil, succeeds:"t0"}`
    — the additive `succeeds` key. `cwd` and `cmd` are written as nil;
    `board_id` and `inherit_cwd_from` are omitted.

        87 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d a7 74 65 72 6d 5f
        69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18 a3 63 77
        64 c0 a3 63 6d 64 c0 a8 73 75 63 63 65 65 64 73 a2 74 30

20. (issue #348) `{t:"report", term_id:"t1", kind:"blocked", text:"ok?"}` — new
    additive cli→daemon type. Keys in the order `rmp_serde::to_vec_named` writes
    them.

        84 a1 74 a6 72 65 70 6f 72 74 a7 74 65 72 6d 5f 69 64 a2 74
        31 a4 6b 69 6e 64 a7 62 6c 6f 63 6b 65 64 a4 74 65 78 74 a3
        6f 6b 3f

21. (issue #348) `{t:"report", term_id:"t1", kind:"clear"}` — the same type with
    no `text`, which is omitted, not nil.

        83 a1 74 a6 72 65 70 6f 72 74 a7 74 65 72 6d 5f 69 64 a2 74
        31 a4 6b 69 6e 64 a5 63 6c 65 61 72

22. (issue #348) `{t:"term_report", term_id:"t1", kind:"done", text:"ok",
    at_ms:1700000000000, proc:"claude", read:true}` — new additive daemon→app
    type with every key; `at_ms` is a msgpack uint64 (`cf`).

        87 a1 74 ab 74 65 72 6d 5f 72 65 70 6f 72 74 a7 74 65 72 6d
        5f 69 64 a2 74 31 a4 6b 69 6e 64 a4 64 6f 6e 65 a4 74 65 78
        74 a2 6f 6b a5 61 74 5f 6d 73 cf 00 00 01 8b cf e5 68 00 a4
        70 72 6f 63 a6 63 6c 61 75 64 65 a4 72 65 61 64 c3

23. (issue #348) `{t:"term_report", term_id:"t1"}` — no report. Every optional
    key is omitted, and `read: false` is omitted too.

        82 a1 74 ab 74 65 72 6d 5f 72 65 70 6f 72 74 a7 74 65 72 6d
        5f 69 64 a2 74 31

24. (issue #348) `{t:"input", term_id:"t1", bytes:"a", typed:true}` — the
    additive `typed` key; `bytes` is `bin` (`c4 01 61`). With `typed: false` the
    key is omitted and the frame is vector 3's shape.

        84 a1 74 a5 69 6e 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31
        a5 62 79 74 65 73 c4 01 61 a5 74 79 70 65 64 c3
