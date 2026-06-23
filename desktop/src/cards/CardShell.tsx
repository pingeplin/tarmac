// The shared card frame: world-space positioning, the 30px header (drag-to-move),
// and the resting chrome classes derived from the ported CardChrome rule. Doc and
// terminal cards supply their own header content + body. Deliberately NOT
// focusable — clicking a card must never steal keyboard focus from the prime
// terminal (design principle #2).

import { useRef, type ReactNode, type PointerEvent as ReactPointerEvent } from "react";
import { borderRole, cardChromeState, showsHandles } from "../kit/cardChrome";
import type { WorldFrame } from "../board/model";

interface CardShellProps {
  frame: WorldFrame;
  className?: string;
  dead?: boolean;
  detached?: boolean;
  fresh?: boolean;
  prime?: boolean;
  focused?: boolean;
  selected?: boolean;
  header: ReactNode;
  children: ReactNode;
  /** Screen→world scale for drag (1/zoom). */
  getZoom: () => number;
  /** Called with the new frame as the header is dragged. */
  onMove?: (frame: WorldFrame) => void;
  /** Called when the user grabs the header (raise to front / focus). */
  onGrab?: () => void;
}

export function CardShell(props: CardShellProps) {
  const { frame, getZoom, onMove, onGrab } = props;
  const dragStart = useRef<{ px: number; py: number; fx: number; fy: number } | null>(null);

  const chrome = cardChromeState({
    dead: props.dead,
    detached: props.detached,
    fresh: props.fresh,
    prime: props.prime,
    focused: props.focused,
    selected: props.selected,
  });
  const role = borderRole(chrome);
  const classes = ["card"];
  if (role === "focus") classes.push("border-focus");
  else if (role === "muted") classes.push("border-muted");
  if (props.prime) classes.push("prime");
  if (props.fresh) classes.push("fresh");
  if (props.dead) classes.push("dead");
  if (props.className) classes.push(props.className);

  const onHeaderPointerDown = (e: ReactPointerEvent) => {
    if (e.button !== 0) return;
    onGrab?.();
    if (!onMove) return;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    dragStart.current = { px: e.clientX, py: e.clientY, fx: frame.x, fy: frame.y };
  };
  const onHeaderPointerMove = (e: ReactPointerEvent) => {
    const s = dragStart.current;
    if (!s || !onMove) return;
    const zoom = getZoom();
    onMove({
      ...frame,
      x: s.fx + (e.clientX - s.px) / zoom,
      y: s.fy + (e.clientY - s.py) / zoom,
    });
  };
  const onHeaderPointerUp = (e: ReactPointerEvent) => {
    if (dragStart.current) (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
    dragStart.current = null;
  };

  // Scroll over a card scrolls the card (terminal scrollback / doc), never pans
  // the board; pinch (ctrl+wheel) still bubbles to the board to zoom.
  const onBodyWheel = (e: React.WheelEvent) => {
    if (!e.ctrlKey) e.stopPropagation();
  };

  return (
    <div
      className={classes.join(" ")}
      style={{ left: frame.x, top: frame.y, width: frame.w, height: frame.h }}
      data-handles={showsHandles(chrome)}
    >
      <div
        className="card-header"
        onPointerDown={onHeaderPointerDown}
        onPointerMove={onHeaderPointerMove}
        onPointerUp={onHeaderPointerUp}
      >
        {props.header}
      </div>
      <div className="card-body" onWheel={onBodyWheel}>
        {props.children}
      </div>
    </div>
  );
}
