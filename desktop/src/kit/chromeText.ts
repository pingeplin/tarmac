// Tiny pure formatters for the P4 chrome overlays: the zoom-control percent
// readout, the titlebar-chip label fallback, and the peek-header recency meta.
// Kept here (not inlined) so the rounding/fallback/window rules are unit-tested;
// recencyLabel takes nowMs (no Date.now in kit) for deterministic tests.

/** Zoom readout, e.g. 1 -> "100%", 0.125 -> "13%". Rounds half away from zero,
 * matching Swift `Int((zoom * 100).rounded())`. */
export function formatZoomPct(zoom: number): string {
  return `${Math.round(zoom * 100)}%`;
}

/** Titlebar chip label: the board's display name, falling back to its id when the
 * name is absent OR empty. Swift uses `name ?? id` (nil-only); the empty-string
 * guard is a deliberate port hardening so an empty name never renders a blank
 * chip. */
export function boardChipLabel(name: string | null | undefined, boardId: string): string {
  return name && name.length > 0 ? name : boardId;
}

/** The 30s recency window (matches DocStore.RECENT_WINDOW_MS / isRecent). */
export const RECENT_WINDOW_MS = 30_000;

/** On-card / peek recency meta `✎ Ns`, or null when the doc has no change time or the
 * last change is at/older than the 30s window. The gate mirrors DocStore.isRecent
 * exactly — a future-dated change time (mtime/clock skew) counts as recent, matching
 * Swift's RecentMetaLabel, which clamps elapsed to 0 and still renders `✎ 1s`.
 * Seconds = round(max(0, now - last)/1000), floored at 1. */
export function recencyLabel(lastChangedMs: number | undefined, nowMs: number): string | null {
  if (lastChangedMs === undefined) return null;
  if (!(nowMs < lastChangedMs || nowMs - lastChangedMs < RECENT_WINDOW_MS)) return null;
  const secs = Math.max(1, Math.round(Math.max(0, nowMs - lastChangedMs) / 1000));
  return `✎ ${secs}s`;
}
