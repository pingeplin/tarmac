# In-app QA driver — manual QA (spec 2609.0015, #166)

Q1, Q4 and Q5 of [`2609.0015_in_app_qa_driver.md`](../../.blueprint/specs/2609.0015_in_app_qa_driver.md).
These three are `[Q]` scenarios because each is a property of a **build** or of a
**window**, not of the code: `make test` runs debug, so nothing automated can
observe a release binary; `make qa` cannot test its own entry condition; and
whether WebKit services `requestAnimationFrame` behind another window is an
observation, not an assertion.

Q2 and Q3 belong to stage 2 (`type`, `key`, `resize`) and are not run here.

**CAUTION: do NOT `pkill tarmacd` or `pkill tarmac-app`.** That kills the user's
installed Tarmac and every terminal its daemon owns. `make run` pins
`TARMAC_SOCKET`, `TARMAC_STATE` and `TARMAC_DEV_SOCKET` under this worktree's
`.dev/`, so the dev app and an installed app coexist. `make kill-daemon` is the
correct tool — it resolves the pid by `lsof` on *this worktree's* socket.

---

## Q1 — the driver is absent from a release build

Three gates, one predicate each. All three must hold.

| # | Gate | How to observe |
|---|---|---|
| 1 | `#[cfg(debug_assertions)]` on the CLI verb | `cd core && cargo build --release && ./target/release/tarmac dev snapshot` |
| 2 | `#[cfg(debug_assertions)]` on the endpoint | `make bundle`, launch `dist/Tarmac.app`, then `ls`/`lsof` its channel dir for `tarmac-dev.sock` |
| 3 | `import.meta.env.DEV` on the frontend half | `cd desktop && npm run build && grep -rl "dev-request\|installDevDriver" dist/` |

### Result — all three gates: PASS (2026-09-16, `make bundle` of `516dcaa`)

- **Gate 1.** `core/target/release/tarmac dev snapshot` printed
  `tarmac: driver unavailable in release builds` and exited **1** — not the
  exit-2 unknown-command path, which is what it would do without the explicit
  `#[cfg(not(debug_assertions))]` arm in `main.rs`.
- **Gate 3.** `npm run build` produced 6 asset files; `grep -rl` for
  `dev-request`, `installDevDriver` and `dev_ready` across `dist/` matched
  **nothing**. Vite eliminates the dynamic import behind `import.meta.env.DEV`
  entirely, so the driver is not merely inert in a production bundle — it is not
  in it.

### Result — gate 2, and gates 1/3 re-checked on the shipped artifact

`make bundle` produced `dist/Tarmac.app`. Checked its **actual shipped
binaries**, which is stronger than the `ls`/`lsof` the spec suggested: an absent
socket has several possible causes, absent *code* has one.

```
$ dist/Tarmac.app/Contents/MacOS/tarmac dev snapshot
tarmac: driver unavailable in release builds        # exit 1
```

Strings in `dist/Tarmac.app/Contents/MacOS/tarmac-app` (the release app, with the
production frontend bundle embedded):

| needle | count |
|---|---|
| `dev-request` | 0 |
| `tarmac-dev.sock` | 0 |
| `installDevDriver` | 0 |
| `dev_ready` | 0 |
| `app_unresponsive` | 0 |
| `not_focused` | 0 |
| `daemon-status` *(control — must be present)* | 1 |

So the endpoint, its socket path literal, its error codes and the whole frontend
half are absent from the release build, not merely unreachable in it. The control
row is what makes the zeros mean something.

**Launching the bundle was deliberately skipped.** A release app resolves the
*release* channel socket — the one the user's installed Tarmac is already on — so
launching it would have put a second window on their live daemon. The static
evidence above answers the same question without touching it.

---

## Q4 — `make qa` with no app listening

**Result: PASS (2026-09-16, `8e90b62`).** With no `make run` app, `make qa`
printed

```
make qa: no dev driver socket at …/.dev/tarmac-dev.sock — start the app with `make run` first
```

and exited non-zero, running **no** scenario. Neither a green suite nor a
scenario-shaped failure — both would be a lie about what was checked. `scripts/`
is TDD exception 3 and the `[D]` suite cannot test its own entry condition, so
this hand-run is the only check on it.

---

## Q5 — does `requestAnimationFrame` stall behind another window?

The settle is "two animation frames **or** 100 ms, whichever comes first"
(Decision 15). The cap exists for a **named but unverified** risk: WebKit is
documented to throttle rAF for an occluded window, and a driver invoked from a
shell is *expected* to run with Tarmac behind the terminal. Nothing in this repo
has observed it in the real Tauri WKWebView, and Tarmac's invariant is that a
reported fact is an observed one — so the cap is labelled a bound, not a fix, and
this scenario is what settles it in either direction.

Run `make qa` three times against one `make run` app: window frontmost, window
fully covered by another window, and window minimised. For each, record the
`visibility` the run header prints, whether every scenario passed, and whether the
settle ended on the second frame or on the cap.

- If rAF keeps running while occluded, the cap is harmless dead weight and can be
  dropped in a follow-up.
- If it stalls, the cap is load-bearing and this is the evidence.

Until this runs, **no doc in this repo may state the rAF-suspension claim as
fact.**

### Result: PASS — and the cap is load-bearing (2026-09-16, `8e90b62` + the seam commit)

Run against a debug `make run` of this worktree, dev app pid 83882, addressed by
pid (two `tarmac-app` processes were on the machine — the installed 0.12.3 and
this one).

**1. Hidden, cap at its shipped 100 ms.** `make qa` → **11/11 passed**, header
`visibility visible`. Median `tarmac dev focus <term>` wall time, 5 runs each:

| window state | median | spread |
|---|---|---|
| frontmost | 130 ms | 118-157 |
| hidden (`System Events`, `visible = false`) | 225 ms | 208-235 |

**2. The knockout — one knob, one factor.** `SETTLE_CAP_MS` 100 → 1500, nothing
else, Vite HMR only (no relaunch):

| window state | median | spread |
|---|---|---|
| frontmost | 134 ms | 116-138 — unchanged |
| hidden | 1743 ms | 1633-1751 — **the full cap** |

Reverted; `make qa` 11/11 again.

**Conclusion: `requestAnimationFrame` does not fire at all for a hidden window.**
Frontmost, the settle ends on the second frame and the cap is never reached —
raising it changes nothing. Hidden, the settle runs to whatever the cap is, which
means without one it would wait until the backend's 2 s bound and every verb
would come back `app_unresponsive`. Decision 15's cap is **not** a hedge against a
documented-but-unobserved behaviour; it is the thing that makes the driver usable
in its most normal posture — called from a shell with Tarmac behind the terminal.

**Correction this run forces on the spec.** `visibility` reported `"visible"` the
whole time the app was hidden: `document.visibilityState` does not flip for a
hidden macOS *application*, only for an occluded/minimised *page*. The field is
still honest — it reports what the DOM says — but Decision 16's claim that it is
"what makes that state readable" is **wrong for app-hiding**, the exact case that
matters here. Keep the field (it still catches minimise and a genuinely hidden
page), and stop citing it as the diagnostic for a slow run; the latency delta
above is the real tell.

**Not run:** minimised (⌘M) as distinct from hidden. Worth adding if the
distinction ever matters; the hidden case is the one a shell-driven run is in.

---

## Incidental finding — the unit tests could not have caught the reactor bug

Worth recording because it bounds what the `[S]` tier is worth here. The first
`make run` of the endpoint aborted at startup:

```
thread 'main' panicked at src/dev_driver.rs:168:
there is no reactor running, must be called from the context of a Tokio 1.x runtime
```

`tokio::net::UnixListener::from_std` was being called from Tauri's `setup`, which
runs *outside* the async runtime. Every backend unit test passed, because
`#[tokio::test]` always provides a reactor — the one context the production call
site does not have. The fix splits the claim (std, in `setup`) from the reactor
registration (`into_async`, inside the spawned task).

The `[S]` tier cannot see this class of bug at all. `make qa` found it on its
first live run, which is the argument for the `[D]` tier existing.
