# Tarmac wire protocol — v1 (M0 + M1 subsets)

Authoritative contract between `tarmacd` (Rust daemon), the `tarmac` CLI, and the
macOS app. Both sides implement exactly this; the conformance vectors at the bottom
are mandatory tests in both codebases. Unknown message *types* received by any party
are ignored (log and continue), not fatal.

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

## Handshake

First frame from any client:

    {t:"hello", role:"cli"|"app", v:1}

Daemon replies `{t:"hello_ok", v:1}`. Unsupported version or role:
`{t:"err", msg:"..."}` then close.

## CLI session (short-lived)

    → {t:"open", path:"/abs/canonical/path.md"}
    ← {t:"ack"}  |  {t:"err", msg}

- `path` MUST be absolute and canonicalized by the CLI before sending.
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
    {t:"input", term_id, bytes:<bin>}
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
    {t:"err", msg}                          — non-fatal notice

## File watching semantics

Watch the doc's **parent directory** (non-recursive) and filter events to the doc
path — editors and agents replace files atomically, so watching the file inode
directly misses rewrites. On a hit, stat the file for mtime. Debounce per path: at
most one `file_event` per 100 ms burst. If the file is deleted, stop emitting until
the path exists again (M0 has no doc_removed message).

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
| `repo_color` | uint 0–3 \| nil | nil | daemon-computed palette index (algorithm below); nil iff `repo` is nil (the app hashes its fallback name locally with the same algorithm) |
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

This matches the app's existing `Theme.repoColor(for:)` byte-for-byte; colors users
saw in M0 peek headers must not change. (Reference values: `payments-api`→3,
`search-svc`→2, `infra`→1.)

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

Sets the doc's `read := true`. Idempotent — the app may send it on every peek
presentation. A path not in the registry is ignored.

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

The current foreground process name on a terminal (the file basename of the
process-group leader's executable). The daemon polls the pty's controlling
process group (`tcgetpgrp` via `MasterPty::process_group_leader`) and resolves
the executable path (`proc_pidpath` on macOS); it pushes a `term_proc` only when
the name **changes** (deduped; pushed once on the first resolve). The app sets
the term card's header label to `name` (the honest "card title = process name").

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal whose foreground process this is |
| `name` | string (required) | — | foreground process name (executable basename) |
| `pid` | int \| nil | nil | the process-group leader pid, when resolvable (diagnostic) |

    {t:"bell", term_id}                              — daemon → app

A BEL byte (`0x07`) was seen in the terminal's output stream. The daemon scans
forwarded output chunks for `0x07` and pushes `bell` debounced to at most one per
~250 ms. The app gives the term card an amber (`#fdbc4b`) signal that clears on
the next keystroke to that terminal or when it regains focus.

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `term_id` | string (required) | — | the terminal that rang the bell |

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
