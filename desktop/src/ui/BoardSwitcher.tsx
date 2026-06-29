// ⌘K board switcher overlay (port of BoardSwitcherView.swift + the AppController
// key model). A centered panel over a dim veil; keyboard-driven with type-to-filter.
//
// KEY DESIGN DECISIONS:
// - No real <input>: we render filter/rename text as a styled <span> with a CSS
//   caret, exactly like Swift's custom NSTextField — never steals keyboard focus
//   from the prime terminal (Principle #2).
// - All button elements: onMouseDown preventDefault + tabIndex={-1} so clicks don't
//   move focus away from the terminal.
// - ALL state (filter / selection / editing / editBuffer / confirmingDelete) lives in
//   App, not here — this is a pure render + click component (mirrors AppController).
//   The key handler also lives in App's global keydown listener.

import type { BoardRow } from "../kit/boardSwitcher";

export interface BoardSwitcherProps {
  visible: boolean;
  rows: BoardRow[];
  /** Currently highlighted row index (keyboard-driven from App). */
  selected: number;
  /** Current filter text (shown in the query line when not editing). */
  query: string;
  /** True while inline rename mode is active. */
  editing: boolean;
  /** The text buffer during a rename. */
  editBuffer: string;
  /** True while delete-confirm is armed. */
  confirmingDelete: boolean;
  /** Display name of the board awaiting delete confirmation, or null. */
  deleteTarget: string | null;
  /** Veil-click or external dismiss (e.g. Escape handled in App). */
  onDismiss: () => void;
  /** Row click (index in the visible rows array). */
  onPickRow: (index: number) => void;
}

/** A simple spinner: rotates a unicode arc via CSS animation when live. */
function Spinner({ live }: { live: boolean }) {
  const frames = ["◜", "◝", "◞", "◟"];
  // Static glyph when not live — we don't drive a real timer here (pure render).
  const glyph = live ? frames[Math.floor(Date.now() / 200) % frames.length] : "○";
  return (
    <span className={`switcher-spinner${live ? " live" : ""}`} aria-hidden>
      {glyph}
    </span>
  );
}

export function BoardSwitcher(props: BoardSwitcherProps) {
  const { visible, rows, selected, query, editing, editBuffer, confirmingDelete, deleteTarget } = props;

  if (!visible) return null;

  // The query/rename bar text: in rename mode show editBuffer, else show filter.
  const queryText = editing ? editBuffer : query;
  // Placeholder when empty and not editing.
  const placeholder = editing ? "rename…" : "switch to…";

  return (
    <>
      {/* Dim veil — click dismisses the switcher. */}
      <div
        className="switcher-veil"
        onMouseDown={(e) => {
          e.preventDefault();
          props.onDismiss();
        }}
        aria-hidden
      />

      {/* The switcher panel. pointer-events:auto so scroll + row clicks work. */}
      <div
        className="switcher-panel"
        role="dialog"
        aria-label="Board switcher"
        onMouseDown={(e) => e.preventDefault()} // don't steal focus on click inside panel
      >
        {/* Query / rename bar */}
        <div className="switcher-query">
          <span className="switcher-query-label">{editing ? "rename:" : "⌘K"}</span>
          <span className="switcher-query-text">
            {queryText || <span className="switcher-query-placeholder">{placeholder}</span>}
            {/* Blinking caret; always shown in the query line (keyboard-driven). */}
            <span className="switcher-caret" aria-hidden>
              ▌
            </span>
          </span>
        </div>

        {/* Board list */}
        <div className="switcher-list" role="listbox">
          {rows.length === 0 && (
            <div className="switcher-empty">no boards match</div>
          )}
          {rows.map((row, i) => {
            const isSelected = i === selected;
            return (
              <div
                key={row.boardID}
                className={`switcher-row${row.isActive ? " active" : ""}${isSelected ? " selected" : ""}`}
                role="option"
                aria-selected={isSelected}
                onMouseDown={(e) => {
                  e.preventDefault();
                  props.onPickRow(i);
                }}
              >
                {/* Live indicator strip */}
                <Spinner live={row.isLive} />

                {/* Board name */}
                <span className="switcher-name">
                  {row.display}
                  {row.isActive && <span className="switcher-active-mark" aria-label="active"> ●</span>}
                </span>

                {/* Meta line (N running · M bell · K cards) */}
                <span className="switcher-meta">{row.meta}</span>

                {/* ⌘1–9 ordinal hint on first nine rows */}
                {i < 9 && (
                  <span className="switcher-ordinal" aria-label={`⌘${i + 1}`}>
                    ⌘{i + 1}
                  </span>
                )}
              </div>
            );
          })}
        </div>

        {/* Footer hint (or delete-confirm prompt) */}
        <div className="switcher-footer">
          {confirmingDelete && deleteTarget ? (
            <span className="switcher-footer-confirm">
              ⌘⌫ again to delete <strong>"{deleteTarget}"</strong> · esc cancel
            </span>
          ) : editing ? (
            <span className="switcher-footer-hint">⏎ confirm · esc cancel rename</span>
          ) : (
            <span className="switcher-footer-hint">
              ⏎ switch · ⌘N new · ⌘E rename · ⌘⌫ delete
            </span>
          )}
        </div>
      </div>
    </>
  );
}
