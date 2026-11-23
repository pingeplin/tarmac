# Tarmac dev workflow

> **Doc status: ACTIVE** — normative. Docs index: [`README.md`](README.md).

How an idea becomes shipped code. The issue number is the thread that ties
**issue → branch → worktree → commit → PR → board card** together. Everything
below is derivable from the issue, so most of it is automatable (see
`/issue` and `/start` skills in `.claude/skills/`).

## Issues

An issue is the unit of work. Title mirrors Conventional Commits so one
vocabulary spans issues, commits, and PRs.

- **Title:** `type(scope): summary` — the `type` and `scope` set of commits
  (`feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`; `release` is for
  a version bump only). Scope optional.
  - `fix(board): close button on doc card is a no-op`
  - `feat: editable doc cards`
- **Labels:** keep the default `bug` / `enhancement` / `documentation` set for
  filtering. The title prefix is the source of truth for *type*; labels are for
  triage views.
- **Body:** use the templates in `.github/ISSUE_TEMPLATE/`. For bugs, lead with
  the **observed OS fact** — Tarmac's invariant is that every on-screen mark is
  backed by an observable fact, so a good bug report names the fact that's wrong
  (process state, mtime, socket call, bell, exit) and what was expected.

## Branches

`type/N-slug` — Conventional type, issue number, short kebab slug.

```
fix/34-doc-card-close
feat/40-editable-docs
chore/41-cask-bump
```

- `type` and `slug` come from the issue title; `N` is the issue number.
- Never work directly on `main`. One branch per issue. The `commit-msg` hook
  refuses a commit on `main`; a merge, a cherry-pick or revert that git
  finishes, a rebase and the first commit of a repository are not refused. A
  release is run from `main`, but `scripts/release.sh` commits the version bump
  on a `release-x.y.z` branch and lands it by PR.

## Worktrees

One worktree per in-flight issue, so an agent can churn on `fix/34` while `main`
stays clean — this is the parallel-agent workflow Tarmac is built for.

- **Location:** sibling to the repo, **outside** the working tree:
  `../tarmac-worktrees/34-doc-card-close/`. Keeping them outside avoids the
  daemon's `notify` watcher and cargo discovering sibling copies.
- **Branch name == dir slug.** Created together.
- **A new worktree has no `app/Vendor/`.** It is gitignored; `make app` (or
  `make ghostty-vt` alone) stages the pinned libghostty-vt XCFramework before
  the Swift package can build. `make run` in a worktree pins its own socket and
  state under that worktree's `.dev/`, so worktrees never share a daemon.
- **Lifecycle:** `git worktree add` on start; `git worktree remove` after the PR
  merges. Run `git worktree prune` if a dir was deleted manually.
- Worktrees are optional for small fixes — a plain branch is fine. Reach for a
  worktree when something else is occupying `main` or an agent runs unattended.

## Commits

Conventional Commits (whole history conforms): `type(scope): summary`. End the
message with **two trailers**: the DCO `Signed-off-by:` that `CONTRIBUTING.md`
requires (`git commit -s`), and the `Co-Authored-By:` the repo uses for
attribution.

Checks hold the form, so it is not reviewed by reading. The `commit-msg` hook
(`make setup` installs it) refuses a subject of another form, a commit on
`main`, and a message with no sign-off of its author or committer; `.github/workflows/dco.yml` refuses an
unsigned commit on a PR (`make dco-check` locally). `pre-commit` runs the format
check, the lints and the tree checks on what is staged, and `pre-push` runs
`make test`. A hook can be skipped (`git commit --no-verify`, a clone with no
`make setup`); CI cannot. The squash merge makes the PR title the subject (of
a PR with one commit, GitHub proposes that commit's subject), so CI holds the
title to the same subject rule (`.github/workflows/pr.yml`). An agent in Claude Code gets most of them sooner, after
each edit and at the end of a turn (not clippy, which needs the whole build). `CLAUDE.md` (*Build, run, test*) is the one
description of what each hook runs.

`make test` must pass first; see [`coding-style.md`](coding-style.md) for the TDD
workflow it gates. For a change to Rust, run `make mutants` before the review:
it changes the lines you changed, one expression at a time, and names each
change that no test saw. The `mutants (rust, in diff)` CI job runs the same
command on every PR. No hook runs it, because it takes minutes.

## PRs

- Open with `gh pr create`; body includes `Closes #N` so the merge closes the
  issue automatically, or `Refs #N` when the PR is one part of the issue.
- **Squash-merge**, keeping the `(#N)` suffix GitHub appends. The squashed
  commit subject should itself be a valid Conventional Commit.
- `.github/workflows/pr.yml` (job `pr-check`, `scripts/check/pr.mjs`) refuses
  a title that is not `type(scope): summary` or that ends in its own `(#N)`, a
  body with no `Closes #N` or `Refs #N` (GitHub's other closing keywords count;
  text in an HTML comment does not), and a branch that is not `type/N-slug`. The
  release PR of `scripts/release.sh` (branch `release-x.y.z`, title
  `release: …`) needs no issue line and no such branch.
- A GitHub "Revert" PR (branch `revert-N-…`, title `Revert "…"`) does not pass:
  open the revert as `fix: revert …` from a `type/N-slug` branch.
- After merge: delete the branch and `git worktree remove` the worktree.
