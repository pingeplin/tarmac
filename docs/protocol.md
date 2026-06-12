# Tarmac wire protocol — v1 (M0 subset)

Authoritative contract between `tarmacd` (Rust daemon), the `tarmac` CLI, and the
macOS app. Both sides implement exactly this; the conformance vectors at the bottom
are mandatory tests in both codebases. Unknown message *types* received by any party
are ignored (log and continue), not fatal.

## Transport

Unix stream socket.

- Default path: `~/Library/Application Support/tarmac/tarmacd.sock`
- Env override: `TARMAC_SOCKET=<path>` — honored by daemon, CLI, and app (tests/dev).
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

daemon → app:

    {t:"output", term_id, bytes:<bin>}      — raw pty bytes, read order, chunks ≤ 64 KiB
    {t:"exit", term_id, code:<int>|nil}     — child exited (nil = killed by signal);
                                              the term's resources are gone after this
    {t:"doc_opened", path, via:"cli"|"user"}
    {t:"file_event", path, mtime_ms:<uint>} — see File watching
    {t:"err", msg}                          — non-fatal notice

## File watching semantics

Watch the doc's **parent directory** (non-recursive) and filter events to the doc
path — editors and agents replace files atomically, so watching the file inode
directly misses rewrites. On a hit, stat the file for mtime. Debounce per path: at
most one `file_event` per 100 ms burst. If the file is deleted, stop emitting until
the path exists again (M0 has no doc_removed message).

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
