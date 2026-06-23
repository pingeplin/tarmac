// Port of TarmacKit/CardChrome.swift — the pure rule for a card's resting
// visual chrome: its border role and whether the resize handles show. Collapses
// `focused`/`selected` into one "active card" state (teal ring + handles, always
// together) and keeps both `prime` (keyboard target) and `fresh` (agent-opened,
// unread) OUT of the border — prime is signalled by header tint + shadow, fresh
// by its halo + "✚ now" meta in the view layer, never by a border here.

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
 * True when the card is the user's active target — a single click (`focused`) or
 * an explicit header/handle grab (`selected`). NOT suppressed by dead/detached:
 * a dead card stays resizable via a header grab, so its handles can still show
 * even though its border is muted.
 */
export function showsHandles(s: CardChromeState): boolean {
  return s.focused || s.selected;
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
