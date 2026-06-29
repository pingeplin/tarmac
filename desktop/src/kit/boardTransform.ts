// Port of TarmacKit/BoardTransform.swift — the pure world↔view transform for the
// v4 board (crib §5):
//   view  = (world − center) · zoom + viewportCenter
//   world = (view − viewportCenter) / zoom + center
//
// `center` is the viewport's world-space center (`board.cx/cy`); `viewportCenter`
// is the board view's own view-space midpoint. Both spaces are top-down (the
// board is flipped). Living here keeps the math the single, unit-testable source
// of truth, separate from the view layer that renders it.

import type { Point } from "./geom";

export function worldToView(
  p: Point,
  zoom: number,
  center: Point,
  viewportCenter: Point,
): Point {
  return {
    x: (p.x - center.x) * zoom + viewportCenter.x,
    y: (p.y - center.y) * zoom + viewportCenter.y,
  };
}

export function viewToWorld(
  p: Point,
  zoom: number,
  center: Point,
  viewportCenter: Point,
): Point {
  return {
    x: (p.x - viewportCenter.x) / zoom + center.x,
    y: (p.y - viewportCenter.y) / zoom + center.y,
  };
}
