---
name: tarmac
description: "How to surface files as cards on the Tarmac board with `tarmac open`, and how to author self-contained HTML cards that satisfy Tarmac's sandbox CSP and its frozen-zoom layout model. Use when working inside Tarmac, when a file is worth showing the user as a card, or when writing an HTML report, chart, or dashboard to be displayed on the board."
---

# Tarmac

Tarmac is a terminal-first macOS cockpit. Its command line is `tarmac`.

```sh
tarmac open <path>   # show a file as a live card on the board
tarmac skill         # print the full guide for coding agents
```

**Run `tarmac skill` and read all of its output before you write an HTML
card.** An HTML card runs in a strict sandbox and a frozen-zoom layout, and a
page that breaks their rules fails silently: a blank or broken card, with no
error. The rules are in the guide and not in this file, because the guide
always matches the installed `tarmac` and this file does not change with it.

To show a markdown file, `tarmac open <path>` is all you need. To update a
card, write to the same path again.

If `tarmac` is not found, or exits non-zero, continue your task. Tarmac may
not be running, and that is never a reason to stop.
