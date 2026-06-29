// Port of TarmacKit/CardChrome.swift — the pure rule for a card's resting
// visual chrome: its border role and the set of resize handles. Collapses
// `focused`/`selected` into one "active card" state for the teal ring; keeps
// both `prime` (keyboard target) and `fresh` (agent-opened, unread) OUT of the
// border — prime is signalled by header tint + shadow, fresh by its halo + "✚ now"
// meta in the view layer, never by a border here.
// Handle hit-areas are always live (hover-revealed via CSS); borderRole stays
// focus-gated so idle cards never show the focus ring.

import type { Handle } from "./resize";

export interface CardChromeState {
  dead: boolean;
  detached: boolean;
  /** Agent-opened and unread — signalled by halo + "✚ now" meta, NOT a border input. */
  fresh: boolean;
  /** The keyboard target — NOT a border input. */
  prime: boolean;
  focused: boolean;
  selected: boolean;
}

/** The resting border role; the card view maps each to a theme colour. */
export type BorderRole = "muted" | "focus" | "plain";

export const cardChromeState = (s: Partial<CardChromeState> = {}): CardChromeState => ({
  dead: false,
  detached: false,
  fresh: false,
  prime: false,
  focused: false,
  selected: false,
  ...s,
});

/**
 * True when the card is the user's active target — used by borderRole to gate
 * the focus ring. NOT used to gate handle hit-areas (those are always live).
 */
export function showsHandles(s: CardChromeState): boolean {
  return s.focused || s.selected;
}

const ALL_HANDLES: readonly Handle[] = ["tl", "t", "tr", "r", "br", "b", "bl", "l"];

/**
 * The ordered set of resize handle ids for a card. `hasClose` drops `"tr"` so
 * the close button and the corner handle never collide; the `"t"` edge strip is
 * right-trimmed in CSS via the `has-close` class.
 */
export function cardHandles(hasClose: boolean): Handle[] {
  return hasClose ? ALL_HANDLES.filter(h => h !== "tr") : [...ALL_HANDLES];
}

/**
 * The resting border role, highest priority first:
 *   dead || detached   -> "muted"  (handles may still show — resize)
 *   active (focus/sel.) -> "focus"  (the unified ring)
 *   else               -> "plain"
 * Neither `prime` nor `fresh` appears — both are signalled outside the border.
 */
export function borderRole(s: CardChromeState): BorderRole {
  if (s.dead || s.detached) return "muted";
  if (showsHandles(s)) return "focus";
  return "plain";
}
