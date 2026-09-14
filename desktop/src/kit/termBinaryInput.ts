// xterm's `onBinary` delivers binary strings — one char per byte (its default
// mouse encoding drops a report rather than emit a code above 255). They must
// reach the PTY as those bytes: `termInput`'s string path is UTF-8, which would
// split any byte ≥ 0x80 (a mouse report past column or row 95) in two.
export function binaryBytes(data: string): number[] {
  return Array.from(data, (c) => c.charCodeAt(0));
}
