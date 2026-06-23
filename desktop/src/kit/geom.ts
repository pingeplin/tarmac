// Shared 2-D value types for the ported board math. These stand in for the
// Swift CoreGraphics types the TarmacKit modules used:
//   CGPoint -> Point   (x, y)
//   CGSize  -> Size    (w, h)   [Swift: width/height]
//   CGRect  -> Rect    (x, y, w, h)  origin + size, top-left, flipped board space
//
// The board's coordinate space is top-down/flipped (matching the AppKit board),
// so larger y is lower on screen. Keep these as plain data; helpers are pure.

export interface Point {
  x: number;
  y: number;
}

export interface Size {
  w: number;
  h: number;
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export const point = (x: number, y: number): Point => ({ x, y });
export const size = (w: number, h: number): Size => ({ w, h });
export const rect = (x: number, y: number, w: number, h: number): Rect => ({ x, y, w, h });

export const rectMidX = (r: Rect): number => r.x + r.w / 2;
export const rectMidY = (r: Rect): number => r.y + r.h / 2;
export const rectMaxX = (r: Rect): number => r.x + r.w;
export const rectMaxY = (r: Rect): number => r.y + r.h;
export const rectCenter = (r: Rect): Point => ({ x: rectMidX(r), y: rectMidY(r) });

export const rectContains = (r: Rect, p: Point): boolean =>
  p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
