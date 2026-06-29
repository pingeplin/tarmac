// The 27px bottom status bar (port of StatusBar.swift, trimmed for the slice):
// agent glyph + board name + connection word on the left, card count on the right.

interface StatusBarProps {
  connected: boolean;
  reason?: string | null;
  cards: number;
}

export function StatusBar(props: StatusBarProps) {
  return (
    <div className="status-bar">
      <span className="agent">▞</span>
      <span>tarmac</span>
      {props.connected ? (
        <span className="connected">attached</span>
      ) : (
        <span className="detached">{props.reason ?? "detached"}</span>
      )}
      <span className="spacer" />
      <span>
        {props.cards} {props.cards === 1 ? "card" : "cards"}
      </span>
    </div>
  );
}
