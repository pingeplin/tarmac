// Pure toast lifecycle: the queue + expiry + overflow rules for the bottom-right
// transient notification stack. The Swift original lived entirely in the untested
// AppKit layer (Toasts.swift + AppController posting), so this is its FIRST unit
// coverage. Time is INJECTED (nowMs) so vitest drives expiry deterministically —
// mirroring docStore.isRecent; never call Date.now() in here. View concerns
// (slide/fade animation, 280px truncation, the chip action closures) stay in the
// ToastOverlay component; only the count/TTL/ordering rules live here.

export const MAX_TOASTS = 3;
export const TOAST_TTL_MS = 7000;

export interface ToastChip {
  /** The chip label (e.g. "undo"); its action closure lives in the view layer. */
  label: string;
}

export interface Toast {
  id: string;
  /** A leading mono glyph: "¶" for connection toasts, "›_" for shell toasts. */
  icon: string;
  title: string;
  body: string | null;
  chips: ToastChip[];
  expiresAtMs: number;
}

export interface ToastState {
  /** Insertion order; newest is LAST (rendered at the bottom of the stack). */
  toasts: Toast[];
}

export const emptyToasts: ToastState = { toasts: [] };

/** Append a toast as the newest (bottom), expiring at nowMs + TTL. When the stack
 * would exceed MAX_TOASTS the OLDEST (first) is evicted — matching Swift's
 * relayout that drops entries.last on a 4th insert. No dedup/coalesce: identical
 * toasts stack independently (parity). */
export function addToast(
  state: ToastState,
  t: Omit<Toast, "expiresAtMs">,
  nowMs: number,
): ToastState {
  const toast: Toast = { ...t, expiresAtMs: nowMs + TOAST_TTL_MS };
  const next = [...state.toasts, toast];
  if (next.length > MAX_TOASTS) next.splice(0, next.length - MAX_TOASTS);
  return { toasts: next };
}

/** Drop every toast whose TTL has elapsed (expiresAtMs <= nowMs). */
export function pruneExpired(state: ToastState, nowMs: number): ToastState {
  const kept = state.toasts.filter((t) => t.expiresAtMs > nowMs);
  return kept.length === state.toasts.length ? state : { toasts: kept };
}

/** Remove a single toast by id (chip dismiss / manual) — never the whole stack. */
export function dismissToast(state: ToastState, id: string): ToastState {
  const kept = state.toasts.filter((t) => t.id !== id);
  return kept.length === state.toasts.length ? state : { toasts: kept };
}

/** Clear the entire stack (the ESC ladder's toast rung). */
export function clearAllToasts(state: ToastState): ToastState {
  return state.toasts.length === 0 ? state : emptyToasts;
}
