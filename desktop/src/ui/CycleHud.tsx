// Transient top-center readout for ⌥Tab terminal cycling. Pointer-events:none
// (pure readout, click-through). Mirrors Swift AppController.cycleTerminals() HUD.

interface CycleHudProps {
  /** null when hidden; else the live-terminal labels + the new prime's index. */
  hud: { labels: string[]; activeIndex: number } | null;
}

export function CycleHud(props: CycleHudProps) {
  if (!props.hud) return null;
  return (
    <div className="cycle-hud">
      {props.hud.labels.map((l, i) => (
        <span
          key={i}
          className={`cycle-hud-item${i === props.hud!.activeIndex ? " active" : ""}`}
        >
          {l || "shell"}
        </span>
      ))}
    </div>
  );
}
