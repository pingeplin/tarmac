# Tarmac dev workflow

How an idea becomes shipped code. The issue number is the thread that ties
**issue → branch → worktree → commit → PR → board card** together. Everything
below is derivable from the issue, so most of it is automatable (see
`/issue` and `/start` skills in `.claude/skills/`).

## Issues

An issue is the unit of work. Title mirrors Conventional Commits so one
vocabulary spans issues, commits, and PRs.

- **Title:** `type(scope): summary` — same `type`/`scope` set as commits
  (`feat`, `fix`, `refactor`, `perf`, `docs`, `chore`). Scope optional.
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
- Never work directly on `main`. One branch per issue.

## Worktrees

One worktree per in-flight issue, so an agent can churn on `fix/34` while `main`
stays clean — this is the parallel-agent workflow Tarmac is built for.

- **Location:** sibling to the repo, **outside** the working tree:
  `../tarmac-worktrees/34-doc-card-close/`. Keeping them outside avoids the
  daemon's `notify` watcher and cargo/Vite discovering sibling copies.
- **Branch name == dir slug.** Created together.
- **Lifecycle:** `git worktree add` on start; `git worktree remove` after the PR
  merges. Run `git worktree prune` if a dir was deleted manually.
- Worktrees are optional for small fixes — a plain branch is fine. Reach for a
  worktree when something else is occupying `main` or an agent runs unattended.

## Commits

Conventional Commits (whole history conforms). End the message with the
`Co-Authored-By:` trailer the repo uses (not the DCO `Signed-off-by` that
CONTRIBUTING mentions — follow the de-facto pattern). `make` must pass first.

## PRs

- Open with `gh pr create`; body includes `Closes #N` so the merge closes the
  issue automatically.
- **Squash-merge**, keeping the `(#N)` suffix GitHub appends. The squashed
  commit subject should itself be a valid Conventional Commit.
- After merge: delete the branch and `git worktree remove` the worktree.
