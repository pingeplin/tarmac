// Shared card-header chrome: kind glyph, repo dot, label, owner chip, fresh
// marker, recency label, and the close button. `children` renders between the
// recency label and the close button — HtmlCard's console badge is the only user.

import { useEffect, useState, type ReactNode } from "react";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";

interface CardHeaderProps {
  glyph: string;
  repoColor?: number | null;
  label: string;
  ownerName?: string | null;
  fresh?: boolean;
  lastChangedMs?: number;
  onClose: () => void;
  children?: ReactNode;
}

export function CardHeader(props: CardHeaderProps) {
  // 1Hz tick, only while inside the 30s window. When recencyLabel goes null we early-
  // return (schedule nothing) so a stale doc stops re-rendering; a fresh file_event
  // changes lastChangedMs, re-running this effect and restarting the tick.
  const [recencyTick, setRecencyTick] = useState(0);
  useEffect(() => {
    if (props.lastChangedMs === undefined) return;
    if (recencyLabel(props.lastChangedMs, Date.now()) === null) return;
    const id = window.setTimeout(() => setRecencyTick((n) => n + 1), 1000);
    return () => window.clearTimeout(id);
  }, [props.lastChangedMs, recencyTick]);
  const recency =
    props.lastChangedMs !== undefined ? recencyLabel(props.lastChangedMs, Date.now()) : null;

  const dotColor =
    props.repoColor != null ? repoColors[props.repoColor % repoColors.length] : undefined;

  return (
    <>
      <span className="glyph">{props.glyph}</span>
      {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
      <span className="label">{props.label}</span>
      <span className="spacer" />
      {props.ownerName && <span className="owner-chip">{"← "}{props.ownerName}</span>}
      {props.fresh && <span style={{ color: "var(--agent)" }}>✚ now</span>}
      {recency && <span className="recency-meta">{recency}</span>}
      {props.children}
      <span
        className="close"
        onPointerDown={(e) => { e.stopPropagation(); e.preventDefault(); }}
        onClick={props.onClose}
        title="Close"
      >
        ✕
      </span>
    </>
  );
}
