---
name: start
description: Start work on a Tarmac GitHub issue — read it, derive the type/N-slug branch, optionally create a sibling worktree, and get to a ready-to-code state per docs/workflow.md. Use when the user says "start issue 34", "start <N>", "begin work on #N", "pick up issue X", "make a branch for this issue", or wants to open a worktree for an issue.
---

# /start <N> — open work on an issue

Take a GitHub issue number and get to a ready-to-work state: correct branch,
optional worktree, following `docs/workflow.md`. `<N>` is the issue number (also
accept a bare number or `#N`).

## Steps

1. **Read the issue.**
   ```
   gh issue view <N> --json number,title,labels,body
   ```
   If no number was given, list open issues (`gh issue list`) and ask which.

2. **Derive the branch name** `type/N-slug`:
   - `type` = the Conventional prefix from the issue title (`fix`, `feat`,
     `refactor`, `perf`, `docs`, `chore`). If the title has no prefix, infer from
     the label (`bug`→`fix`, `enhancement`→`feat`) or ask.
   - `N` = issue number.
   - `slug` = the title summary, lowercased, kebab-cased, stop-words trimmed,
     ~3–5 words (e.g. `doc-card-close`). Drop the scope from the slug.
   - Result: `fix/34-doc-card-close`.

3. **Choose branch vs worktree.** Default to a plain branch. Use a **worktree**
   when the user asks, when `main`/the working tree is occupied, or when an agent
   will run unattended. If unsure and the change looks non-trivial, ask.

   **Plain branch** (from an up-to-date `main`):
   ```
   git fetch origin
   git switch -c <branch> origin/main
   ```

   **Worktree** (sibling dir, outside the repo tree per docs/workflow.md):
   ```
   git fetch origin
   git worktree add ../tarmac-worktrees/<N>-<slug> -b <branch> origin/main
   ```
   Then tell the user to `cd ../tarmac-worktrees/<N>-<slug>` (you cannot persist a
   cd; mention it explicitly). Keep worktrees out of the repo so the daemon's
   `notify` watcher and cargo/Vite don't pick up sibling copies.

4. **Sanity check** you're on the new branch (`git status`), branched from latest
   `origin/main`, and the tree is clean. Surface the issue's acceptance criteria /
   key body points as the working checklist.

5. **Hand off.** State the branch, the location (repo or worktree path), and a
   one-line plan from the issue. Don't start coding unless asked — `/start` opens
   the work; implementation is the next step. When done, `/ship` (or a manual
   Conventional commit + `gh pr create` with `Closes #N`) finishes it.

## Notes
- Never branch off a dirty tree — stash or ask first.
- If a branch/worktree for `<N>` already exists, switch to it instead of
  recreating.
- Build verification is `make` (the source of truth, not the editor) — remind
  before any PR, but `/start` itself doesn't build.
