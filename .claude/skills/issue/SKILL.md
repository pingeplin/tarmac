---
name: issue
description: Turn a rough thought into a well-formed Tarmac GitHub issue — Conventional-Commit-style title, the right label, and a structured body following docs/workflow.md. Use when the user wants to "file an issue", "open a GitHub issue", "capture this bug/idea", "make an issue for X", or describes a bug/feature to track.
---

# /issue — capture a well-formed issue

Create a GitHub issue for `pingeplin/tarmac` that follows the conventions in
`docs/workflow.md`. The issue's title and body are the seed that `/start` later
turns into a branch and worktree, so get the type and slug right.

## Steps

1. **Classify the type.** From the user's description pick one Conventional type:
   `fix` (something behaves wrong), `feat` (new/improved capability), `refactor`,
   `perf`, `docs`, `chore`. Add a `scope` if one is obvious (`board`, `terminal`,
   `protocol`, `m3`, …) — scope is an area tag, not a path.

2. **Write the title** as `type(scope): summary` — imperative, lowercase, no
   trailing period. This mirrors the commit convention so it carries through to
   the branch and PR.

3. **Pick the label:** `bug` for `fix:`, `enhancement` for `feat:`,
   `documentation` for `docs:`, none for `chore`/`refactor`/`perf` unless one
   clearly fits. Don't invent labels.

4. **Fill the body** using the matching template under
   `.github/ISSUE_TEMPLATE/`:
   - **Bug** → lead with the **observed OS fact** that's wrong (process state,
     mtime, `tarmac open` socket call, bell, exit, a card/edge), then expected,
     repro, environment. This is Tarmac's core invariant — a bug is a fact that
     disagrees with the screen.
   - **Feature** → what / why / acceptance (prefer observable, OS-fact-backed
     checks) / notes.
   - **Chore** → task + checklist.
   Only include sections you can actually fill; don't leave hollow placeholders.

5. **Confirm, then create.** Show the user the drafted title + body and the
   label. On approval run:
   ```
   gh issue create --title "<title>" --label "<label>" --body "<body>"
   ```
   (omit `--label` if none). Report the new issue number and URL.

6. **Offer the handoff:** ask if they want to `/start <N>` it now.

## Notes
- If the description is too thin to classify or write acceptance, ask one or two
  sharp questions first — don't file a vague issue.
- Batch related thoughts into one issue; split genuinely separate work into
  separate issues so each gets its own branch.
