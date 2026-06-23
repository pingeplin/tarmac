// Tests for the pure toast lifecycle reducer (queue, expiry, overflow eviction,
// dismiss, clear-all). Net-new coverage — the Swift toast logic was never
// extracted to TarmacKit, so there is no Swift test to mirror.

import { describe, it, expect } from "vitest";
import {
  addToast,
  pruneExpired,
  dismissToast,
  clearAllToasts,
  emptyToasts,
  MAX_TOASTS,
  TOAST_TTL_MS,
  type Toast,
} from "./toasts";

const mk = (id: string, title = id): Omit<Toast, "expiresAtMs"> => ({
  id,
  icon: "¶",
  title,
  body: null,
  chips: [],
});

describe("addToast", () => {
  it("sets expiresAtMs = nowMs + TTL and appends as the newest (last)", () => {
    const s = addToast(emptyToasts, mk("a"), 1000);
    expect(s.toasts).toHaveLength(1);
    expect(s.toasts[0]!.expiresAtMs).toBe(1000 + TOAST_TTL_MS);
  });

  it("keeps the newest at the bottom (last) across adds", () => {
    let s = addToast(emptyToasts, mk("a"), 0);
    s = addToast(s, mk("b"), 0);
    expect(s.toasts.map((t) => t.id)).toEqual(["a", "b"]);
  });

  it("evicts the OLDEST when exceeding MAX_TOASTS, keeping #2..#4 in order", () => {
    let s = emptyToasts;
    for (const id of ["a", "b", "c", "d"]) s = addToast(s, mk(id), 0);
    expect(s.toasts).toHaveLength(MAX_TOASTS);
    expect(s.toasts.map((t) => t.id)).toEqual(["b", "c", "d"]);
  });

  it("does not coalesce identical toasts (no dedup — parity)", () => {
    let s = addToast(emptyToasts, mk("a", "same"), 0);
    s = addToast(s, mk("b", "same"), 0);
    expect(s.toasts).toHaveLength(2);
  });
});

describe("pruneExpired", () => {
  it("keeps a toast one ms before expiry and drops it AT expiry (<=)", () => {
    const s = addToast(emptyToasts, mk("a"), 1000); // expiry = 1000 + TTL
    expect(pruneExpired(s, 1000 + TOAST_TTL_MS - 1).toasts).toHaveLength(1);
    expect(pruneExpired(s, 1000 + TOAST_TTL_MS).toasts).toHaveLength(0);
  });
});

describe("dismissToast", () => {
  it("removes only the targeted id, leaving the rest + their expiry untouched", () => {
    let s = addToast(emptyToasts, mk("a"), 0);
    s = addToast(s, mk("b"), 5);
    const out = dismissToast(s, "a");
    expect(out.toasts.map((t) => t.id)).toEqual(["b"]);
    expect(out.toasts[0]!.expiresAtMs).toBe(5 + TOAST_TTL_MS);
  });
});

describe("clearAllToasts", () => {
  it("empties the stack regardless of expiry", () => {
    let s = addToast(emptyToasts, mk("a"), 0);
    s = addToast(s, mk("b"), 0);
    expect(clearAllToasts(s).toasts).toHaveLength(0);
  });
});
