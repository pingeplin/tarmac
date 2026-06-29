# IME second-keystroke drop in terminal cards — root cause + fix

Status: implemented
Area: desktop (Tauri UI), `desktop/src/cards/TerminalCard.tsx`

## Symptom

In a terminal card, with a CJK IME active but switched to English/alphanumeric
mode, fast typing dropped characters (notably the second of a fast pair). Slow
typing was fine; no CJK composition was on screen.

## Root cause (confirmed by live event tracing)

On macOS, a CJK input source in alphanumeric mode delivers each ASCII letter as a
**committed `insertText`** carried in a composition-style cycle, and fires the DOM
events in an order xterm.js does not expect:

```
input   {data:"a", inputType:"insertText", isComposing:false}   ← input FIRST
keydown {key:"a", keyCode:229, isComposing:false}               ← keydown AFTER
```

xterm's `CompositionHelper` assumes `keydown → input`: on a `keyCode:229` keydown
it snapshots the textarea and diffs it on a deferred `setTimeout(0)`. Because
`input` fires *before* `keydown` here, the baseline snapshot already includes the
new char, and the single-flight diff loses characters under fast bursts. The lost
keys never reach `term.onData`.

This is upstream-ordering-dependent, so patching xterm's textarea-diff cannot win
the race — it is the wrong layer.

Real-keyCode keys (space, punctuation) are different: they arrive `keydown →
input` with a real keyCode, so xterm delivers them correctly via its own keydown
path **and** they still emit an `insertText`.

## The fix

`desktop/src/cards/TerminalCard.tsx` — intercept the authoritative committed text
on `beforeinput` and send it straight to the PTY, bypassing xterm's lossy diff:

- On `beforeinput` with `inputType === "insertText"`, `!isComposing`, non-null
  `data`: `preventDefault()` (so the textarea never mutates → xterm's diff path is
  a no-op and cannot echo) and `termInput(data)`.
- Real compositions (`isComposing`) and non-insert edits (deletes, etc.) are left
  to xterm untouched.
- **Echo dedupe**: real-keyCode keys (space, punctuation) are sent by xterm's own
  keydown path via `onData` *and* emit an `insertText`. `onData` records the last
  emitted `{data, time}`; the `beforeinput` handler drops its send when it matches
  within 16 ms. Letters (keyCode 229) never hit `onData`, so they are always sent
  by the interceptor; space/punctuation are always sent by `onData`. Exactly one
  send per key.

No xterm patch is needed — the earlier `patch-package` approach was removed.

## Why it's safe

- CJK composition is untouched: the `isComposing` guard skips every keystroke that
  builds or commits a real composition; those still flow through xterm's
  `CompositionHelper`.
- `imeGuard.ts` / `App.tsx` are unchanged. The `keyCode === 229` check in
  `imeGuard` remains load-bearing for the first keystroke of a genuine composition.
- Option-as-meta and the terminal key bindings are unaffected — the interceptor
  only handles `insertText`, never modifier/control keys.
- Verified live: fast English-mode bursts drop nothing; space is sent once; Pinyin
  / Zhuyin compositions commit exactly once with no stray ASCII.

## Manual QA checklist

IME behavior is not unit-testable; verify in the running desktop app.

1. CJK source in English mode, fast-type a long ASCII string — every char arrives,
   no drops.
2. Spaces and punctuation appear exactly once (no duplicates).
3. Plain US keyboard — fast typing and auto-repeat unaffected.
4. Pinyin/Zhuyin composition — candidate window, commit; only committed Hanzi
   reach the PTY.
5. Commit-then-type-fast — committed CJK then immediate ASCII both arrive in order.
6. Key bindings (⌘K/⌘W/⌘T, switcher, Enter, Esc) and ⌥-as-meta still behave.
