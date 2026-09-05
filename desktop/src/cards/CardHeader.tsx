// Shared card-header chrome: kind glyph, repo dot, label, owner chip, fresh
// marker, recency label, the refresh control, and the close button. `children`
// renders between the refresh control and the close button — HtmlCard's console
// badge is the only user.

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
  onRefresh?: () => void;
  onClose: () => void;
  children?: ReactNode;
}

interface HeaderButtonProps {
  className: string;
  title: string;
  onClick: () => void;
  children: ReactNode;
}

/** A header control. Swallows pointerdown so a click never starts the header
 *  drag — load-bearing for every button, so it lives in one place. */
export function HeaderButton(props: HeaderButtonProps) {
  return (
    <span
      className={props.className}
      onPointerDown={(e) => { e.stopPropagation(); e.preventDefault(); }}
      onClick={props.onClick}
      title={props.title}
    >
      {props.children}
    </span>
  );
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
      {props.onRefresh && (
        <HeaderButton className="refresh" onClick={props.onRefresh} title="Refresh from disk">
          ↻
        </HeaderButton>
      )}
      {props.children}
      <HeaderButton className="close" onClick={props.onClose} title="Close">
        ✕
      </HeaderButton>
    </>
  );
}
