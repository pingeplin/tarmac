// Fixed bottom pane that hosts the docked prime terminal. The terminal's xterm
// host node is reparented here imperatively (via DockContext.dockSlot) so the
// PTY and scrollback survive without a remount. Mirrors Swift DockPaneView.

interface DockPaneProps {
  visible: boolean;
  /** Docked terminal's display label (or "shell"). */
  label: string;
  /** App publishes this to DockContext.dockSlot via setDockSlot. */
  bodyRef: (el: HTMLElement | null) => void;
}

/** Always mounted; `visible` toggles display via the `hidden` class. */
export function DockPane(props: DockPaneProps) {
  return (
    <div className={`dock-pane${props.visible ? "" : " hidden"}`}>
      <div className="dock-header">
        <span className="glyph">›_</span>
        <span className="label">{props.label || "shell"}</span>
        <span className="spacer" />
        <span className="hint">esc ↩</span>
      </div>
      {/* .dock-body must have NO React children; the host is appended imperatively. */}
      <div className="dock-body" ref={props.bodyRef} />
    </div>
  );
}
