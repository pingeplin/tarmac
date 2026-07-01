// Authored previews for ToastOverlay — the bottom-right transient toast stack
// (port of Toasts.swift, desktop/src/ui/ToastOverlay.tsx). Pure render over a
// `toasts: Toast[]` list (owned/lifecycled by kit/toasts.ts) + an
// `onChipClick` callback; empty list renders null (not a useful story). The
// real variant axis: icon/title/body combos, presence/absence of chips, and
// stack depth up to kit/toasts.ts's MAX_TOASTS=3 (oldest→newest, newest
// rendered at the bottom).
//
// GOTCHA (see DocCard.tsx for the full writeup): `.toast-stack` is `position:
// absolute; right: 14px; bottom: 38px` — pinned to the board's bottom-right
// corner. The single-story capture wrapper has zero intrinsic height with
// only this absolutely-positioned child, so `bottom: 38px` resolves against a
// 0-height box and the stack renders off the top of the frame. Wrapping in a
// board-sized `position: relative` box (~800x600, per the "overlay wants
// board-sized" guidance) gives it a real corner to pin against.
import { ToastOverlay } from "tarmac-app";

const noop = () => {};

const frame = { position: "relative" as const, width: 800, height: 600 };

/** The common two-toast case straight from kit-fixtures.mjs: a chip-less doc
 * toast plus a shell-exit toast with an "undo" chip. */
export function Default() {
  return (
    <div className="board" style={frame}>
      <ToastOverlay
        toasts={[
          {
            id: "t1",
            icon: "¶",
            title: "doc opened",
            body: "README.md",
            chips: [],
            expiresAtMs: Date.now() + 7000,
          },
          {
            id: "t2",
            icon: "›_",
            title: "shell exited",
            body: null,
            chips: [{ label: "undo" }],
            expiresAtMs: Date.now() + 7000,
          },
        ]}
        onChipClick={noop}
      />
    </div>
  );
}

/** A single bare toast: no body line, no chips — the minimal shape (e.g. a
 * plain connection notice). */
export function SingleToast() {
  return (
    <div className="board" style={frame}>
      <ToastOverlay
        toasts={[
          {
            id: "t1",
            icon: "¶",
            title: "daemon connected",
            body: null,
            chips: [],
            expiresAtMs: Date.now() + 7000,
          },
        ]}
        onChipClick={noop}
      />
    </div>
  );
}

/** A full stack at kit/toasts.ts's MAX_TOASTS=3, mixing chip-bearing and
 * chip-less toasts and a long title to exercise the 280px ellipsis
 * truncation — oldest ("board created") first/top, newest last/bottom. */
export function FullStack() {
  return (
    <div className="board" style={frame}>
      <ToastOverlay
        toasts={[
          {
            id: "t1",
            icon: "¶",
            title: "board created",
            body: "release-0.7",
            chips: [],
            expiresAtMs: Date.now() + 7000,
          },
          {
            id: "t2",
            icon: "›_",
            title: "shell exited unexpectedly with a much longer status line",
            body: "exit code 137",
            chips: [{ label: "restart" }, { label: "dismiss" }],
            expiresAtMs: Date.now() + 7000,
          },
          {
            id: "t3",
            icon: "¶",
            title: "doc opened",
            body: "docs/protocol.md",
            chips: [{ label: "undo" }],
            expiresAtMs: Date.now() + 7000,
          },
        ]}
        onChipClick={noop}
      />
    </div>
  );
}
