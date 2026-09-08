# Tarmac — coding style & TDD

> **Doc status: ACTIVE** — normative. The rules new code on `main` is held to.
> See the [docs index](README.md) for how the doc set is classified, and
> [`workflow.md`](workflow.md) for issue → branch → commit → PR mechanics.

[`../CLAUDE.md`](../CLAUDE.md) carries the summary every agent session loads.
This is the reference behind it: the rules you cannot infer from the summary,
each anchored to code that already does it. Rules bind **new code**; where the
tree predates a rule, that is said inline.

---

## 1. TDD is mandatory

**Red → green → refactor.** Write the failing test first, watch it fail, make it
pass with the smallest change, then clean up under a green suite. A PR whose test
was written after the code it tests is not done, even if the suite is green.

**Red means observed-red, for the reason you predicted.** Run the new test
against the unmodified tree and read the failure. A test that passes before your
change tests something else that happened to be true.

Test-first fails to *compile* or resolve before it ever fails an assertion, and
that is not yet red. Introduce the symbol under test as a stub — `todo!()` in
Rust, a function returning a placeholder in TypeScript — then observe the
assertion fail. Run just the test you are driving:

| Suite | Command (from the repo root) |
| --- | --- |
| Rust | `cd core && cargo test -p <crate> <name>` — `<crate>` is `tarmacd`, `tarmac-protocol`, or `tarmac-cli`; the wrong one reports a green "0 passed" |
| Tauri backend | `cd desktop/src-tauri && cargo test <name>` |
| Frontend | `cd desktop && npx vitest run <file>` — `npm test` typechecks first and would stop before Vitest ever runs |

**Green means the smallest change that turns it green** — not the change you
already had in mind. **Refactor only under green**, and change structure or
behaviour, never both in one step.

**A test that would still pass if the behaviour were wrong does not count.** Ask
of each behaviour: what is the smallest change that breaks it, and would this
test catch it?

### 1.1 Where the red test goes

Pick the innermost layer that can express the failure.

| The change is… | The failing test goes… |
| --- | --- |
| A pure decision, transform, or rule in Rust | `#[cfg(test)] mod tests` at the **bottom of the same file** — `core/crates/tarmacd/src/state.rs`, `core/crates/tarmacd/src/term.rs` |
| Daemon behaviour observable over the socket | a suite in `core/crates/tarmacd/tests/` (`boards_integration.rs`, `restore_integration.rs`, …), built on the real-daemon harness in `core/crates/tarmacd/tests/common/mod.rs` |
| The wire contract | `core/crates/tarmac-protocol/src/lib.rs` — a new inline conformance vector, byte-exact. Never edit an existing one; see the additive-only rule in [`protocol.md`](protocol.md) |
| CLI surface (exit codes, stderr, `--help`) | `core/crates/tarmac-cli/tests/cli.rs` — spawn the real binary |
| Frontend logic | a module in `desktop/src/kit/` plus its paired test — `desktop/src/kit/toasts.ts` and `toasts.test.ts` |
| Pure logic already living in `desktop/src/board/` | a test in `desktop/src/kit/` that imports it directly — `desktop/src/kit/zOrder.test.ts` drives `topZ` from `desktop/src/board/model.ts` |
| Tauri-backend logic | `#[cfg(test)] mod tests` at the bottom of the file that owns it — `desktop/src-tauri/src/bridge.rs`, `desktop/src-tauri/src/card_protocol.rs`, and `desktop/src-tauri/src/lib.rs` each carry one |

Name a new integration suite for its subject, not a milestone.

### 1.2 The kit-extraction rule

The React/Tauri GUI layer — `desktop/src/App.tsx`, `desktop/src/board/`,
`desktop/src/cards/`, `desktop/src/ui/` — is not unit-tested by design (root
[`README.md`](../README.md), *Tests*). That is not a licence to skip TDD there;
it is the reason for this rule:

> When a change to the shell contains a **decision** — an ordering, a threshold,
> a predicate, a state transition, a coordinate — extract that decision into
> `desktop/src/kit/` and TDD it there. What stays in the component is wiring:
> read state, call the pure function, apply the result.

`desktop/src/kit/clearFreshDoc.ts`, `desktop/src/kit/toasts.ts`, and
`desktop/src/kit/termCycle.ts` are that move applied to a reset rule, queue
rules, and cycle order; each header records what was left in the view layer. If
you cannot name what you would extract, the change is genuinely wiring: take the
exception below and say so.

### 1.3 Exceptions — the closed list

TDD is waived only where there is no *new* decision to test:

1. **Pure presentation** — CSS, colours, spacing, animation.
2. **Thin wiring** — a handler that only forwards to an already-tested pure
   function; a prop threaded through a component.
3. **Build, packaging, and CI** — `Makefile`, `scripts/`, `packaging/`,
   `.github/workflows/`. Note the design-sync bundle is *not* here:
   `desktop/src/kit-entry.ts` and `desktop/scripts/build-kit.mjs` are covered by
   `desktop/src/kit-build.test.ts`, which runs the real build and asserts on what
   it emits.
4. **Generated or vendored code**, and the doc set itself.
5. **A behaviour-preserving refactor** — no new test; the suite must be green
   before and after. If the refactor needs a *new* test to be safe, it is not
   behaviour-preserving: write that test first.
6. **A dependency bump** — no new test; the suite must be green before and after.

Every exception owes a discharge, named in the PR body. **1 and 2** owe a
verification statement — what you exercised by hand and what you observed. **5**
owes the tests that cover the moved code, green before and after; **6** owes the
green suite alone. **3** owes the build it touches: `make bundle` for the bundle
path, a green CI run for a workflow change, `make test` otherwise — `packaging/`
is reached only by `make release`, so say what you verified there by hand.
**4** owes `make docs-check` for docs, `make test` for generated or vendored
code.

Work driven by a spec in `.blueprint/specs/` records its manual scenarios as a
QA doc under `desktop/qa/` *instead of* the PR-body statement —
`desktop/qa/daemon-relaunch-qa.md` is the shape: the scenario, the build it ran
against, the observed values.

A spike — throwaway code proving something is possible — is exempt because it is
not shipped. Delete it and redo the work test-first.

"There is no harness for this" is a claim to check before using it.
`desktop/src/card-shim.test.ts` tests a shipped `.js` asset by executing it in a
`node:vm`; `desktop/src/cull-probe.test.ts` does the same for a QA probe page.

---

## 2. Style — everywhere

- **Smallest correct diff.** Prefer the narrow change to the thorough one. Do not
  reformat, rename, or reorganise code you are not otherwise changing.
- **Match the surrounding file.** There is no formatter and no linter here — no
  `rustfmt.toml`, no `.editorconfig`, no ESLint, no Prettier — and CI checks
  neither. Do **not** run `cargo fmt`: local rustfmt disagrees with the entire
  committed tree and produces pure churn.
- **One responsibility per module.** Depend on the narrow contract — the `Msg`
  enum, a pure function signature — rather than reaching across a layer.
- **A comment earns its place by explaining a non-obvious *why***: a constraint,
  a workaround, an invariant, a parity requirement. Never restate the line below
  it. Three forms are in use: a header block at the top of a module saying what
  the module deliberately does *not* do; `//` immediately above the line it
  explains; and doc comments (`///` in Rust, `/** … */` in TypeScript) on public
  API. Worked examples:
  - `core/crates/tarmacd/src/conn.rs` (board delete) — states the lock invariant
    the three-step sequence exists to satisfy.
  - `core/crates/tarmacd/src/term.rs` — why `scrollback` is a `std::sync::Mutex`
    and not tokio's.
  - `desktop/src/kit/docKind.ts` — why dotfiles and trailing-dot names resolve
    the way they do (Node `path.extname` parity).
  - `desktop/src/cull-probe.test.ts` — recounts the incident that justifies
    executing the shipped file instead of a copy.
- **Name the unit in the identifier.** Durations and timestamps are integer
  milliseconds and carry `_ms` / `Ms` — on the wire (`mtime_ms`,
  `last_changed_ms` in `core/crates/tarmac-protocol/src/lib.rs`), in persisted
  state, and in local constants (`TOAST_TTL_MS` in
  `desktop/src/kit/toasts.ts`).

## 3. Style — Rust

- **Errors follow the crate's role.** `tarmacd` returns `anyhow::Result` from
  fallible top-level and setup functions. `tarmac-cli` stays std-only: string
  errors, or a small local enum where the caller must distinguish cases
  (`NoHandshake` in `core/crates/tarmac-cli/src/main.rs`). `tarmac-protocol`
  exposes precise library types — `io::Result` for framing, `rmp_serde`'s own
  error types for the codec. There is no repo-wide error enum and no
  `thiserror`; do not introduce one for a single call site.
- **Never `.unwrap()` in `tarmacd` production code.** Where a failure is
  genuinely impossible, say why in a short lowercase string:
  `.expect("active board present")`, `.expect("watcher lock")`. Reserve
  `.unwrap()` for tests. (`desktop/src-tauri/src/bridge.rs` predates this and
  uses `.lock().unwrap()` throughout; new code there follows the `tarmacd`
  pattern, and existing sites stay unless you are changing them anyway.)
- **`let _ =` only for best-effort work** — a channel send whose receiver may be
  gone, cleanup on the way out. Never to silence a failure that matters.
- **Ids are `String` aliases, not newtypes** — `pub type BoardId = String;` in
  `core/crates/tarmacd/src/state.rs`. Do not add a trait to get a seam for
  mocking either: the integration harness spawns the real daemon instead.
- **Getters read as nouns** (`active_board`, `state_path`) — no `get_` prefix.
  Mutators read as verbs (`apply_layout`, `ensure_watched`, `mark_dirty`).
- **`std::sync::Mutex` must never span an `.await`** — lock, do the synchronous
  thing, drop; clone what the slow call needs first. `tokio::sync::Mutex` may be
  held across `.await`. The full rule, and why it is load-bearing, is in
  [`architecture.md`](architecture.md) (*Lock discipline*).
- **Logging follows the binary's lifetime.** The long-running daemon uses
  `tracing` (`debug!`/`info!`/`warn!`/`error!`). The short-lived CLI writes
  results to stdout unprefixed and errors to stderr prefixed `tarmac: ` — a
  usage or help block printed to stderr keeps its own formatting. The protocol
  crate logs nothing.
- **Name test functions as sentences** — `respects_posix_precedence_lc_all_over_lang`,
  not a `test_` prefix. Integration tests drive a real daemon over a real socket
  through `core/crates/tarmacd/tests/common/mod.rs`; add helpers there rather
  than re-implementing a handshake.

## 4. Style — TypeScript & React

- **The layering is one-way.** `desktop/src/board/`, `desktop/src/cards/`,
  `desktop/src/ui/`, and `desktop/src/App.tsx` import runtime code from
  `desktop/src/kit/`. No production module in `kit/` imports runtime code back —
  `import type` only — and none imports React or `@tauri-apps`. (Kit *tests* may
  import `board/` runtime code, to pin a shared constant or to test pure logic
  that already lives there.) Nothing enforces this; a reviewer does.
- **`kit/` takes its world by argument.** No ambient clock, no reaching for
  globals: `desktop/src/kit/toasts.ts` takes `nowMs` as a parameter and
  `createRafCounter` in `desktop/src/kit/rafProbe.ts` takes `now: () => number`,
  leaving the wiring to pick `performance.now()` or `Date.now`. Same for the
  host object, the reporter, and any other side channel.
- **Naming.** React components are PascalCase `.tsx` named for the component.
  Logic modules under `desktop/src/kit/` and `desktop/src/ipc/` are
  lowerCamelCase `.ts`. **Every new `kit/` module ships with its paired
  `.test.ts` beside it.**
- **Types.** `strict` is on in `desktop/tsconfig.json`, and `npm test` runs
  `tsc --noEmit` before Vitest — a type error is a test failure. Export the
  shapes callers need; `interface` for object shapes, `type` for unions and
  aliases. **`any` is banned in `kit/`.** Elsewhere, reach for it only where no
  public type exists — the xterm.js internals and DOM expando properties — and
  write the reason above it. The existing sites predate this rule and carry at
  most an inert `eslint-disable` line (see §5); do not copy that as the
  justification.
- **Errors.** Pure `kit/` functions return a value and never throw for an
  expected condition: `undefined` for "no result", the input unchanged for a
  no-op transform — match the module you are editing. `desktop/src/ipc/daemon.ts`
  lets `invoke` rejections propagate to the caller; swallow one only for a
  fire-and-forget notification, as `frontendReady` does. The shell catches only
  where it can render the failure to the user. Daemon messages are a
  discriminated union on `t` (`desktop/src/ipc/protocol.ts`); an unknown `t` is
  ignored, never an error — the wire is additive-only.
- **Tests.** `describe`/`it`, with plain descriptive titles ("wraps from last to
  first on next"); scenario-driven tests lead with the spec id ("S9: …"). Build
  state with a small local factory inside each test; no `kit/` test uses
  `beforeEach`, and a new one should not need it. Mock at module level only to
  pin a cross-language contract, as `desktop/src/ipc/daemon.test.ts` does for the
  Tauri command names — that file's `beforeEach` resets the shared mock, which is
  what earns it.

## 5. Traps

- **Two different things are called "kit".** `desktop/src/kit/` is the pure-logic
  layer this doc is about. `desktop/src/kit-entry.ts` and
  `desktop/scripts/build-kit.mjs` are an unrelated bundle of presentational
  components for design sync. A rule about one says nothing about the other.
- **`.test.tsx` files never run.** `desktop/vitest.config.ts` includes
  `src/**/*.test.ts` only, in the `node` environment — a component test named
  `Foo.test.tsx` is silently skipped, with no error.
- **`eslint-disable` comments in the tree are inert.** There is no ESLint config;
  they are vestigial. Do not add one expecting it to do anything.
- **Docs are gated.** `make docs-check` enforces the banner, link integrity, and
  that an ACTIVE doc names no path that does not exist; adding the doc's row to
  the index is convention, not enforced. See [`README.md`](README.md).

## 6. Before the PR

1. The test you added was **seen failing** before the code that makes it pass —
   or the change is on the exception list and you have discharged what §1.3 owes
   it.
2. `make test` passes (docs-check plus all three suites).
3. Commits are Conventional and carry both trailers named in
   [`workflow.md`](workflow.md) — the DCO `Signed-off-by:` and `Co-Authored-By:`.
   `make dco-check` verifies the branch.
4. The PR body says `Closes #N`.
