// Host side of the HTML-card console relay (spec 2607.0004): validates the
// shim's postMessage payloads and owns the per-card ring buffer. The shim
// itself lives Rust-side (card_shim.js, prepended by the tarmac-card://
// handler); everything here is pure and unit-tested.

export const CARD_CONSOLE_BUFFER_CAP = 500;

export type CardConsoleLevel = "log" | "info" | "warn" | "error";

export interface CardConsoleEntry {
  level: CardConsoleLevel;
  args: unknown[];
}

export type CardMessage =
  | { kind: "console"; level: CardConsoleLevel; args: unknown[] }
  | { kind: "escape" }
  | { kind: "ready"; meta: string | null };

const LEVELS: readonly string[] = ["log", "info", "warn", "error"];

// Anything that isn't a well-formed Tarmac payload is silently ignored — the
// iframe is untrusted and can post arbitrary messages.
export function parseCardMessage(data: unknown): CardMessage | null {
  if (typeof data !== "object" || data === null) return null;
  const d = data as Record<string, unknown>;
  if (d.tarmac === "escape") return { kind: "escape" };
  if (d.tarmac === "ready") {
    if (typeof d.meta !== "string" && d.meta !== null) return null;
    return { kind: "ready", meta: d.meta };
  }
  if (d.tarmac !== "console") return null;
  if (typeof d.level !== "string" || !LEVELS.includes(d.level)) return null;
  if (!Array.isArray(d.args)) return null;
  return { kind: "console", level: d.level as CardConsoleLevel, args: d.args };
}

// Order-preserving append; beyond the cap the oldest entries fall off.
export function pushCardConsole(
  buf: readonly CardConsoleEntry[],
  entry: CardConsoleEntry,
  cap: number = CARD_CONSOLE_BUFFER_CAP,
): CardConsoleEntry[] {
  const next = [...buf, entry];
  return next.length > cap ? next.slice(next.length - cap) : next;
}

// One display line per entry. Args are already shim-serialized (JSON-safe or
// string placeholders), so objects stringify rather than "[object Object]".
export function formatCardArgs(args: readonly unknown[]): string {
  return args
    .map((a) => (typeof a === "object" && a !== null ? JSON.stringify(a) : String(a)))
    .join(" ");
}
