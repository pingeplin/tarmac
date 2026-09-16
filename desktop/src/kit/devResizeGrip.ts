// The pointer drag `tarmac dev resize <card> <w>x<h>` performs on a card's
// bottom-right grip (spec 2609.0015, issue #166).
//
// Two decisions live here, and both are the difference between resizing the card
// and resizing nothing:
//   - the delta is scaled INTO screen px by zoom, because
//     CardShell.onHandlePointerMove divides by `getZoom()` to get back to board
//     units. A plan that hands over board units resizes by `1/zoom` of what was
//     asked.
//   - clientX/clientY are carried by value on all three events. They are the only
//     fields the resize reads; screenX/screenY would dispatch a zero-delta drag.
//
// All three events go to the same grip element, which is what makes the missing
// pointer capture harmless: CardShell wires onPointerMove/Up on the handle itself,
// so capture only matters for a real pointer that leaves it. Measured (#174
// pre-check 4): WebKit's setPointerCapture with a synthetic pointerId does not
// throw — it silently no-ops — so the handler records the grab and runs on.

import type { Point, Size } from "./geom";

export interface PointerDescriptor {
  type: "pointerdown" | "pointermove" | "pointerup";
  clientX: number;
  clientY: number;
  pointerId: 1;
  pointerType: "mouse";
  isPrimary: true;
  button: 0;
  buttons: number;
  bubbles: true;
  cancelable: true;
}

export function gripDelta(from: Size, to: Size, zoom: number): { dx: number; dy: number } {
  return { dx: (to.w - from.w) * zoom, dy: (to.h - from.h) * zoom };
}

export function gripPlan(centre: Point, delta: { dx: number; dy: number }): PointerDescriptor[] {
  const shared = {
    pointerId: 1,
    pointerType: "mouse",
    isPrimary: true,
    button: 0,
    bubbles: true,
    cancelable: true,
  } as const;
  const end = { clientX: centre.x + delta.dx, clientY: centre.y + delta.dy };
  return [
    { type: "pointerdown", clientX: centre.x, clientY: centre.y, buttons: 1, ...shared },
    { type: "pointermove", ...end, buttons: 1, ...shared },
    { type: "pointerup", ...end, buttons: 0, ...shared },
  ];
}
