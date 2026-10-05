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
Rust, a function returning a placeholder in Swift — then observe the assertion
fail. Run just the test you are driving:

| Suite | Command (from the repo root) |
| --- | --- |
| Rust | `cd core && cargo test -p <crate> <name>` — `<crate>` is `tarmacd`, `tarmac-protocol`, or `tarmac-cli`; the wrong one reports a green "0 passed" |
| Swift | `cd app && swift test --filter <target>.<class>` (or `<target>.<class>/<test>`) — `<target>` is `TarmacKitTests` or `TarmacTermTests`, e.g. `swift test --filter TarmacKitTests.KeyLadderTests`. The package needs `make ghostty-vt` once first |

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
| The wire contract | `core/crates/tarmac-protocol/src/lib.rs` — a new inline conformance vector, byte-exact — **and** the same vector in `app/Tests/TarmacKitTests/ConformanceTests.swift`, with the Rust encoder's bytes for the new frame in `app/Tests/TarmacKitTests/RustEncoderParityTests.swift`. Never edit an existing one; see the additive-only rule in [`protocol.md`](protocol.md) |
| CLI surface (exit codes, stderr, `--help`) | `core/crates/tarmac-cli/tests/cli.rs` — spawn the real binary |
| App logic — a rule, a threshold, an ordering, a state transition, a coordinate | a module in `app/Sources/TarmacKit/` plus its paired test in `app/Tests/TarmacKitTests/` — `app/Sources/TarmacKit/ToastQueue.swift` and `app/Tests/TarmacKitTests/ToastQueueTests.swift` |
| The daemon link | `app/Tests/TarmacKitTests/DaemonClientTests.swift` — the real client against a stand-in daemon on a real Unix socket |
| The terminal card — emulation, frames, drawing, key and mouse translation | a suite in `app/Tests/TarmacTermTests/`, driving a real `TerminalEngine`; `app/Tests/TarmacTermTests/TerminalRendererTests.swift` renders into a bitmap and samples its pixels |

Name a new integration suite for its subject, not a milestone.

### 1.2 The kit-extraction rule

The AppKit shell — the `TarmacApp` target, everything under
`app/Sources/TarmacApp/` — is not unit-tested by design (root
[`README.md`](../README.md), *Tests*). That is not a licence to skip TDD there;
it is the reason for this rule:

> When a change to the shell contains a **decision** — an ordering, a threshold,
> a predicate, a state transition, a coordinate — extract that decision into
> `TarmacKit` and TDD it there. What stays in the view or the controller is
> wiring: read state, call the pure function, apply the result.

`app/Sources/TarmacKit/ClearFreshDoc.swift` and
`app/Sources/TarmacKit/ToastQueue.swift` are that move applied to a reset rule
and queue rules; the second's header records what was left in the view layer. If you cannot name what you would extract, the change is genuinely
wiring: take the exception below and say so.

### 1.3 Exceptions — the closed list

TDD is waived only where there is no *new* decision to test:

1. **Pure presentation** — colours, fonts, spacing, animation.
2. **Thin wiring** — a handler that only forwards to an already-tested pure
   function; a closure threaded through a view.
3. **Build, packaging, and CI** — `Makefile`, `scripts/`, `packaging/`,
   `.github/workflows/`.
4. **Generated or vendored code** — the staged XCFramework, the bundled `marked`
   and fonts — and the doc set itself.
5. **A behaviour-preserving refactor** — no new test; the suite must be green
   before and after. If the refactor needs a *new* test to be safe, it is not
   behaviour-preserving: write that test first.
6. **A dependency bump** — no new test; the suite must be green before and after.

Every exception owes a discharge, named in the PR body. **1 and 2** owe a
verification statement — what you exercised by hand and what you observed. **5**
owes the tests that cover the moved code, green before and after; **6** owes the
green suite alone. **3** owes the build it touches: `make bundle` for the bundle
path, a green CI run for a workflow change, `make test` otherwise — the
signing in `scripts/dmg.sh` and the publishing in `scripts/release.sh` are
reached only by cutting a real release, so say what you verified there by hand. **4** owes `make docs-check` for docs,
`make test` for generated or vendored code.

Work driven by a spec in `.blueprint/specs/` owes that statement per manual
scenario, in one shape: the scenario, the build it ran against, the observed
values. A record that should outlive its PR — a checklist, or a probe page
it needs — goes in `qa/` at the repo root; the ones there from before 2026-10
were run against the Tauri app.

A spike — throwaway code proving something is possible — is exempt because it is
not shipped. Delete it and redo the work test-first.

"There is no harness for this" is a claim to check before using it.
`app/Tests/TarmacKitTests/DaemonClientTests.swift` tests the connection loop
against a daemon it fakes on a real socket;
`app/Tests/TarmacKitTests/DaemonSpawnerTests.swift` observes real child
processes; `app/Tests/TarmacTermTests/TerminalRendererTests.swift` reads pixels
back from a rendered bitmap.

---

## 2. Style — everywhere

- **Smallest correct diff.** Prefer the narrow change to the thorough one. Do not
  reformat, rename, or reorganise code you are not otherwise changing.
- **Match the surrounding file.** There is no formatter and no linter here — no
  `rustfmt.toml`, no `.swiftformat`, no SwiftLint config, no `.editorconfig` —
  and CI checks neither. Do **not** run `cargo fmt`: local rustfmt disagrees with
  the entire committed tree and produces pure churn.
- **One responsibility per module.** Depend on the narrow contract — the `Msg`
  enum, a pure function signature — rather than reaching across a layer.
- **A comment earns its place by explaining a non-obvious *why***: a constraint,
  a workaround, an invariant, a parity requirement. Never restate the line below
  it. Three forms are in use: a header block at the top of a module saying what
  the module deliberately does *not* do; `//` immediately above the line it
  explains; and `///` doc comments on public API, in Rust and Swift alike. Worked
  examples:
  - `core/crates/tarmacd/src/conn.rs` (board delete) — states the lock invariant
    the three-step sequence exists to satisfy.
  - `core/crates/tarmacd/src/term.rs` — why `scrollback` is a `std::sync::Mutex`
    and not tokio's.
  - `app/Sources/TarmacKit/DocKind.swift` — why dotfiles and trailing-dot names
    resolve the way they do, and why `NSString.pathExtension` is not used.
  - `app/Sources/TarmacApp/BoardView.swift` (`restack`) — why cards are sorted in
    place and never re-added to restack them.
  - `app/Sources/TarmacTerm/TerminalGridLayout.swift` — why the whole-cell count
    tolerates a few ulps.
- **Name the unit in the identifier.** Durations and timestamps are integer
  milliseconds and carry `_ms` / `Ms` — on the wire (`mtime_ms`,
  `last_changed_ms` in `core/crates/tarmac-protocol/src/lib.rs`), in persisted
  state, and in local constants (`ttlMs` in
  `app/Sources/TarmacKit/ToastQueue.swift`).

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
  `.unwrap()` for tests.
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

## 4. Style — Swift

- **The layering is one-way.** `TarmacApp` imports `TarmacKit` and `TarmacTerm`;
  `TarmacTerm` imports neither; `TarmacKit` imports no AppKit, no WebKit and
  neither sibling. SwiftPM enforces the target graph (`app/Package.swift`); that
  `TarmacKit` stays free of AppKit, and that a decision does not stay behind in
  the shell, is convention — a reviewer checks it.
- **`TarmacKit` takes its world by argument.** No ambient clock, no environment,
  no timer: `app/Sources/TarmacKit/ScrollbackGate.swift` and
  `app/Sources/TarmacKit/PendingPersists.swift` hand out a generation or a token
  and are told when the caller's timer fired; `QuitGuard` is passed the event's
  bits, the time and the key state; `ChannelPaths` is passed the override and
  the home directory. The few modules that do I/O — the daemon link, the dev
  socket, file reads — keep every decision in a pure sibling, as `DaemonLaunch`
  does for `DaemonClient`.
- **Shape.** A rule is a caseless `enum` of static functions (`KeyLadder`, `Cull`,
  `Placement`); a rule with state is a small value `struct` with `mutating`
  methods (`ScrollbackGate`, `QuitGuard`, `CardBorrow`). One main type per file,
  the file named for it; a slice of the controller is an
  `AppController+<Area>.swift` extension. **Every new kit module ships with its
  paired `<Module>Tests.swift`.** The tree predates this for `CardCull`,
  `DaemonSocket`, `JavaScriptNumber`, `Messages` and `StrictJSON`; a suite that
  spans modules is named for its subject (`ConformanceTests`,
  `RustEncoderParityTests`, `BoardPersistenceTests`).
- **Access and isolation.** `public` is what the shell calls; tests reach the
  rest with `@testable import`. The package builds in Swift 6 language mode:
  views and controllers are `@MainActor`, a kit value type is `Sendable`, and
  `@unchecked Sendable` is for a class that guards its own state with a lock
  (`DaemonClient`, `DevRelay`) — say what guards it.
- **Errors.** A pure kit function returns a value and does not throw for an
  expected condition: `nil` for "nothing to do" (`TermGrid.resize`), a `Result`
  where the caller branches on the failure (`DevPress.plan`, `DevSocket.claim`),
  a decision `enum` otherwise. `throws` is for malformed input
  (`Message.decode(payload:)`) and a failed libghostty-vt call
  (`TerminalEngineError`). An unknown message type decodes to `.unknown` and is
  ignored, never an error — the wire is additive-only. The shell reserves
  `fatalError` for what a correct build cannot reach, such as a missing bundled
  resource.
- **Tests.** XCTest: one `final class <Module>Tests: XCTestCase` per module, test
  names as camelCase sentences —
  `testAddEvictsTheOldestBeyondMaxToastsKeepingTheRestInOrder`; scenario-driven
  tests lead with the spec id — `testS32AChordOutsideTheGrammarIsRefused`. Build
  state with a small private factory inside the class; `setUp`/`tearDown` are for
  a test that owns a real resource — a socket, a temp directory, a child process
  — as `app/Tests/TarmacKitTests/DevSocketTests.swift` does. A `TarmacTerm` test
  class that drives a main-actor type (engine, renderer, view) is `@MainActor`. Pin a cross-language contract
  with bytes captured from the other side, never hand-written, as
  `app/Tests/TarmacKitTests/RustEncoderParityTests.swift` does.

## 5. Traps

- **Two codecs.** A wire change that passes `cargo test` is half done: the Swift
  codec carries its own copy of every conformance vector, and `make test` runs
  both.
- **`swift test` needs `app/Vendor/`.** It is gitignored; until `make
  ghostty-vt` has staged it the package does not resolve, whatever you changed.
- **A wrong `cargo test -p` or `--filter` is green.** Both report zero tests run
  as a pass. Read the count.
- **Docs are gated.** `make docs-check` enforces the banner, link integrity, and
  that an ACTIVE doc names no path that does not exist; adding the doc's row to
  the index is convention, not enforced. See [`README.md`](README.md).

## 6. Before the PR

1. The test you added was **seen failing** before the code that makes it pass —
   or the change is on the exception list and you have discharged what §1.3 owes
   it.
2. `make test` passes (docs-check plus both suites).
3. Commits are Conventional and carry both trailers named in
   [`workflow.md`](workflow.md) — the DCO `Signed-off-by:` and `Co-Authored-By:`.
   `make dco-check` verifies the branch.
4. The PR body says `Closes #N`.
