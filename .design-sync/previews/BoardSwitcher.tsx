// Authored previews for BoardSwitcher — the ⌘K board switcher overlay
// (desktop/src/ui/BoardSwitcher.tsx). All state (filter/selection/editing/
// editBuffer/confirmingDelete) is owned by the caller (App), so BoardSwitcher is
// a pure render+click surface over that state — the interesting variant axis is
// which of its four modes (browse / empty-filter / rename / delete-confirm) is
// active, each of which changes the query bar, the row list, and the footer hint.
// `visible: false` renders `null` (a deliberately empty card) so it isn't a
// useful story here — every export below keeps `visible: true`.
//
// GOTCHA (see DocCard.tsx for the full writeup): both `.switcher-veil`
// (position: absolute; inset: 0) and `.switcher-panel` (position: absolute;
// top/left: 50%; translate(-50%,-50%)) are position:absolute — the
// single-story capture wrapper has zero intrinsic height with only
// absolutely-positioned children, so the panel's "centered" 50%/50% resolves
// against a 0-height box and roughly half the panel renders above the
// viewport. Wrapping in a plain sized `position: relative` box (standing in
// for `.board-stack`, the real positioned ancestor per app-only.css) gives the
// veil+panel a real box to center within.
import { BoardSwitcher } from "tarmac-app";

const noop = () => {};

const frame = { position: "relative" as const, width: 820, height: 600 };

const rows = [
  { boardID: "main", display: "main", isActive: true, isLive: true, running: 2, bell: 0, cards: 5, meta: "2 running · 5 cards" },
  { boardID: "scratch", display: "scratch", isActive: false, isLive: false, running: 0, bell: 1, cards: 2, meta: "1 bell · 2 cards" },
  { boardID: "release-0-7", display: "release-0.7", isActive: false, isLive: true, running: 1, bell: 0, cards: 3, meta: "1 running · 3 cards" },
];

/** The common steady state: mixed active/live/bell rows, nothing typed yet. */
export function Browsing() {
  return (
    <div style={frame}>
      <BoardSwitcher
        visible
        rows={rows}
        selected={0}
        query=""
        editing={false}
        editBuffer=""
        confirmingDelete={false}
        deleteTarget={null}
        onDismiss={noop}
        onPickRow={noop}
      />
    </div>
  );
}

/** Type-to-filter narrowed the list to nothing — the "no boards match" empty
 * state, still showing the typed query in the bar. */
export function NoMatches() {
  return (
    <div style={frame}>
      <BoardSwitcher
        visible
        rows={[]}
        selected={0}
        query="zzz"
        editing={false}
        editBuffer=""
        confirmingDelete={false}
        deleteTarget={null}
        onDismiss={noop}
        onPickRow={noop}
      />
    </div>
  );
}

/** ⌘E inline rename in progress on the highlighted "scratch" row — the query
 * bar swaps to "rename:" + a live edit buffer, and the footer swaps to the
 * confirm/cancel-rename hint. */
export function Renaming() {
  return (
    <div style={frame}>
      <BoardSwitcher
        visible
        rows={rows}
        selected={1}
        query=""
        editing
        editBuffer="scratch-2"
        confirmingDelete={false}
        deleteTarget={null}
        onDismiss={noop}
        onPickRow={noop}
      />
    </div>
  );
}

/** ⌘⌫ armed on "scratch" — the footer swaps to the "press again to delete"
 * confirmation prompt naming the target board. */
export function ConfirmingDelete() {
  return (
    <div style={frame}>
      <BoardSwitcher
        visible
        rows={rows}
        selected={1}
        query=""
        editing={false}
        editBuffer=""
        confirmingDelete
        deleteTarget="scratch"
        onDismiss={noop}
        onPickRow={noop}
      />
    </div>
  );
}
