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
  /** Stacking order (world z) → CSS z-index. */
  z?: number;
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
  /** The card's root element, for the engine's viewport culling (visibility). */
  rootRef?: (el: HTMLDivElement | null) => void;
  /** Called with the new frame as the header is dragged. */
  onMove?: (frame: WorldFrame) => void;
  /** Called as the header drag begins (frame at grab time), for gravity snapshot. */
  onMoveStart?: () => void;
  /** Called when the header drag ends (commit), for detach/persist. */
  onMoveEnd?: () => void;
  /** Called when the user grabs the header (raise to front / focus). */
  onGrab?: () => void;
}

/** Pointer travel (px) past which a header press is treated as a move, not a click. */
const DRAG_THRESHOLD = 3;

export function CardShell(props: CardShellProps) {
  const { frame, getZoom, onMove, onGrab } = props;
  const dragStart = useRef<{ px: number; py: number; fx: number; fy: number } | null>(null);
  const moved = useRef(false);

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
    moved.current = false;
    props.onMoveStart?.();
  };
  const onHeaderPointerMove = (e: ReactPointerEvent) => {
    const s = dragStart.current;
    if (!s || !onMove) return;
    if (Math.abs(e.clientX - s.px) > DRAG_THRESHOLD || Math.abs(e.clientY - s.py) > DRAG_THRESHOLD) {
      moved.current = true;
    }
    const zoom = getZoom();
    onMove({
      ...frame,
      x: s.fx + (e.clientX - s.px) / zoom,
      y: s.fy + (e.clientY - s.py) / zoom,
    });
  };
  const onHeaderPointerUp = (e: ReactPointerEvent) => {
    const wasDragging = dragStart.current !== null;
    if (wasDragging) (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
    dragStart.current = null;
    // Only a real move commits (detach/persist); a click-without-move is just a grab.
    if (wasDragging && moved.current) props.onMoveEnd?.();
    moved.current = false;
  };
  // A cancelled gesture (capture lost, another gesture pre-empts, the card is
  // about to unmount mid-drag) must still settle: commit a real move so the
  // engine clears its gesture state rather than leaving a half-finished drag.
  const onHeaderPointerCancel = () => {
    const wasDragging = dragStart.current !== null;
    dragStart.current = null;
    if (wasDragging && moved.current) props.onMoveEnd?.();
    moved.current = false;
  };

  // Scroll over a card scrolls the card (terminal scrollback / doc), never pans
  // the board; pinch (ctrl+wheel) still bubbles to the board to zoom.
  const onBodyWheel = (e: React.WheelEvent) => {
    if (!e.ctrlKey) e.stopPropagation();
  };

  return (
    <div
      ref={props.rootRef}
      className={classes.join(" ")}
      style={{ left: frame.x, top: frame.y, width: frame.w, height: frame.h, zIndex: props.z }}
      data-handles={showsHandles(chrome)}
    >
      <div
        className="card-header"
        onPointerDown={onHeaderPointerDown}
        onPointerMove={onHeaderPointerMove}
        onPointerUp={onHeaderPointerUp}
        onPointerCancel={onHeaderPointerCancel}
      >
        {props.header}
      </div>
      <div className="card-body" onWheel={onBodyWheel}>
        {props.children}
      </div>
    </div>
  );
}
