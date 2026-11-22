# Contributing to Tarmac

Thanks for your interest in contributing! This document explains how to get
your changes accepted and, importantly, the terms under which contributions are
made.

## License and contribution terms

Tarmac is licensed under the [Apache License 2.0](LICENSE). By submitting a
contribution (a pull request, patch, or any code/documentation), you agree that
your contribution is licensed under the same Apache 2.0 terms, as described in
Section 5 of the license.

### Developer Certificate of Origin (DCO)

To keep the project's provenance clean, every commit must be signed off under
the [Developer Certificate of Origin](https://developercertificate.org/)
(reproduced below). Signing off certifies that you wrote the change or otherwise
have the right to submit it under the project's license.

A DCO is a statement about **provenance, not a transfer of rights**. It is not a
CLA: it grants the maintainer no rights beyond the ones Apache 2.0 already grants
everyone. Relicensing your contribution itself under other terms would require a
CLA, which this project does not use.

Add a sign-off line to each commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

The easiest way is to let git add it automatically:

```sh
git commit -s -m "your message"
```

Use your real name. The checks compare the email: it must be the commit's
author or committer email (your git `user.email`).

`.github/workflows/dco.yml` checks every commit in a pull request; run
`make dco-check` to check your branch before pushing (for a branch stacked on
another branch rather than `main`, pass its base: `make dco-check BASE=origin/…`). Enforcement starts from
that workflow — commits made before it were not signed off, and the history has
deliberately not been rewritten to add them.

<details>
<summary>Developer Certificate of Origin 1.1 (full text)</summary>

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

</details>

## Development setup

Tarmac builds on macOS 26+ with a Rust toolchain and a Swift 6.2+ toolchain
(Xcode; the format and lint checks, and so `make test`, need a `swift format` of
6.3 or 6.4); `make test` and `make dco-check` also need Node.js (plain `node`, no
packages). Build the daemon, the CLI and the app with:

```sh
make core app
```

`make app` first stages the pinned libghostty-vt XCFramework into the gitignored
`app/Vendor/` (a one-time download; `make ghostty-vt` does only that). Until it
is there the Swift package does not resolve, in a terminal or in an editor.

Please make sure `make test` succeeds before opening a pull request. Note that the
editor/IDE may show stale SourceKit diagnostics — `make` is the source of truth.

## Submitting changes

1. Fork the repository and create a topic branch from `main`. Run `make setup`
   once in a new clone (it needs [lefthook](https://lefthook.dev):
   `brew install lefthook`). It installs git hooks that refuse a commit on a
   format, lint, `arch-check` or `docs-check` finding in what is staged, or on
   a message that is not `type(scope): summary` with your sign-off, and refuse
   a push when `make test` fails. `git commit --no-verify` skips them. CI runs
   the same checks (all but the subject's form, which a maintainer sets at the
   squash merge), so the hooks only tell you sooner; each failure names the
   rule, the place and the command to run next. One CI job that no hook runs
   is `mutants (rust, in diff)`: it changes the Rust lines of your pull
   request, one expression at a time, and fails when the tests still pass. Run
   it yourself with `make mutants` (it needs `cargo-mutants` 27.1.0).
   `CLAUDE.md` (*Build, run, test*) describes every check, and the hooks an
   agent in Claude Code gets.
2. Make your change, keeping it focused. Format it with `make fmt` (rustfmt and
   swift-format); do not lay code out by hand.
3. **Work test-first.** Tarmac requires TDD: write the failing test, watch it
   fail on the unmodified tree, then make it pass. The house style, the placement
   table (which layer a given test belongs in), the rule for the AppKit shell —
   which is not unit-tested by design — and the closed list of exceptions are
   all in [`docs/coding-style.md`](docs/coding-style.md). Ensure all suites pass
   (`make test` — it stages libghostty-vt itself; only a bare `swift build` /
   `swift test` or an editor needs `make ghostty-vt` first).
4. Commit with a clear message, a DCO sign-off (`git commit -s`), and the
   `Co-Authored-By:` trailer if someone or something co-wrote the change. Verify
   with `make dco-check`.
5. Open a pull request describing the change and the motivation. If your change
   took one of the TDD exceptions, discharge what
   [`docs/coding-style.md`](docs/coding-style.md) §1.3 asks of it.

## Questions

If you're unsure whether a change fits the project's direction, open an issue to
discuss it before investing significant effort. Thanks for contributing!
