// The shared card frame: world-space positioning, the 30px header (drag-to-move),
// 8 resize handles (4 edges + 4 corners, always-live hit areas, hover-revealed chips),
// and the resting + active chrome classes derived from the ported CardChrome rule.
// Doc and terminal cards supply their own header content + body. Deliberately NOT
// focusable — clicking a card must never steal keyboard focus from the prime terminal
// (design principle #2).

import { useRef, useState, type ReactNode, type PointerEvent as ReactPointerEvent } from "react";
import { borderRole, cardChromeState, cardHandles } from "../kit/cardChrome";
import { resizeFrame, type Handle } from "../kit/resize";
import type { WorldFrame } from "../board/model";

interface CardShellProps {
  frame: WorldFrame;
  /** Stacking order (world z) → CSS z-index. */
  z?: number;
  className?: string;
  dead?: boolean;
  detached?: boolean;
  /** A non-prime card while another terminal is prime (Swift setQuiet, 0.8). */
  quiet?: boolean;
  fresh?: boolean;
  prime?: boolean;
  focused?: boolean;
  selected?: boolean;
  /** The card's header has a close button (doc cards): suppress the top-right
   * resize handle so they never collide (Swift hides tr when a close exists). */
  hasClose?: boolean;
  header: ReactNode;
  children: ReactNode;
  /** Screen→world scale for drag/resize (1/zoom). */
  getZoom: () => number;
  /** When true, the wrapper div in .card-layer owns position via CSS-var transform;
   *  CardShell renders at 0,0 and omits its own left/top. Drag/resize math still
   *  reads the real frame + getZoom() so committed frames stay world-coord. */
  inWrapper?: boolean;
  /** The card's root element, for the engine's viewport culling (visibility). */
  rootRef?: (el: HTMLDivElement | null) => void;
  /** Called with the new frame as the header is dragged. */
  onMove?: (frame: WorldFrame) => void;
  /** Called as the header drag begins (frame at grab time), for gravity snapshot. */
  onMoveStart?: () => void;
  /** Called when the header drag ends (commit), for detach/persist. */
  onMoveEnd?: () => void;
  /** Called with the new frame as a resize handle is dragged. */
  onResize?: (frame: WorldFrame) => void;
  /** Called when a resize ends (commit), for persist. */
  onResizeEnd?: () => void;
  /** Called when the user grabs the header/handle (raise to front / select). */
  onGrab?: () => void;
}

/** Pointer travel (px) past which a header press is treated as a move, not a click. */
const DRAG_THRESHOLD = 3;

export function CardShell(props: CardShellProps) {
  const { frame, getZoom, onMove, onGrab } = props;
  const dragStart = useRef<{ px: number; py: number; fx: number; fy: number } | null>(null);
  const moved = useRef(false);
  const resizeStart = useRef<{ px: number; py: number; frame: WorldFrame; handle: Handle } | null>(null);
  const [lifting, setLifting] = useState(false);

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
  if (props.quiet) classes.push("quiet");
  if (props.detached) classes.push("detached");
  if (props.hasClose) classes.push("has-close");
  if (lifting) classes.push("lifting");
  if (props.className) classes.push(props.className);

  // --- header drag (move) ---
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
      if (!moved.current) setLifting(true); // lift on the first real movement
      moved.current = true;
    }
    const zoom = getZoom();
    onMove({ ...frame, x: s.fx + (e.clientX - s.px) / zoom, y: s.fy + (e.clientY - s.py) / zoom });
  };
  const onHeaderPointerUp = (e: ReactPointerEvent) => {
    const wasDragging = dragStart.current !== null;
    if (wasDragging) (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
    dragStart.current = null;
    setLifting(false);
    // Only a real move commits (detach/persist); a click-without-move is just a grab.
    if (wasDragging && moved.current) props.onMoveEnd?.();
    moved.current = false;
  };
  // A cancelled gesture (capture lost, pre-empted, card about to unmount mid-drag)
  // must still settle so the engine clears its gesture state.
  const onHeaderPointerCancel = () => {
    const wasDragging = dragStart.current !== null;
    dragStart.current = null;
    setLifting(false);
    if (wasDragging && moved.current) props.onMoveEnd?.();
    moved.current = false;
  };

  // --- resize (edges + corners) ---
  const onHandlePointerDown = (e: ReactPointerEvent, handle: Handle) => {
    if (e.button !== 0 || !props.onResize) return;
    e.preventDefault();            // suppress native text selection (反白) at the source
    e.stopPropagation();
    window.getSelection()?.removeAllRanges(); // flush any selection already in progress
    onGrab?.();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    resizeStart.current = { px: e.clientX, py: e.clientY, frame, handle };
    setLifting(true);
  };
  const onHandlePointerMove = (e: ReactPointerEvent) => {
    const s = resizeStart.current;
    if (!s || !props.onResize) return;
    const zoom = getZoom();
    const dx = (e.clientX - s.px) / zoom;
    const dy = (e.clientY - s.py) / zoom;
    props.onResize(resizeFrame(s.frame, s.handle, dx, dy));
  };
  const onHandlePointerUp = (e: ReactPointerEvent) => {
    const wasResizing = resizeStart.current !== null;
    if (wasResizing) (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
    resizeStart.current = null;
    setLifting(false);
    if (wasResizing) props.onResizeEnd?.();
  };
  const onHandlePointerCancel = () => {
    const wasResizing = resizeStart.current !== null;
    resizeStart.current = null;
    setLifting(false);
    if (wasResizing) props.onResizeEnd?.();
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
      style={
        props.inWrapper
          ? { inset: 0 }                                              // fill the real-px wrapper; z lives on the outer wrapper only
          : { left: frame.x, top: frame.y, width: frame.w, height: frame.h, zIndex: props.z }
      }
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
      {props.onResize &&
        cardHandles(props.hasClose ?? false).map((handle) => (
          <div
            key={handle}
            className={`card-handle ${handle}`}
            onPointerDown={(e) => onHandlePointerDown(e, handle)}
            onPointerMove={onHandlePointerMove}
            onPointerUp={onHandlePointerUp}
            onPointerCancel={onHandlePointerCancel}
          />
        ))}
    </div>
  );
}
