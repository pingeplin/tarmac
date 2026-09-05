import { describe, it, expect, vi, beforeEach } from "vitest";

// The doc verbs are one-line `invoke(name, args)` wrappers, and the command name is
// a bare string: `generate_handler!` compile-checks the Rust fn, nothing checks the
// literal here. A verb swap therefore type-checks, passes every other suite, and
// ships — `invoke("doc_close")` inside `docRefresh` would CLOSE the card on click
// (spec 2609.0001). These pin the name and the payload shape; the Rust side of the
// same contract is pinned by commands.rs + lib.rs's generate_handler! list.
// Limitation: they compare against literals, so they catch a swap BETWEEN verbs —
// the dangerous case — but not a typo made identically on both sides.
const invoke = vi.hoisted(() => vi.fn((_cmd: string, _args?: unknown) => Promise.resolve()));
vi.mock("@tauri-apps/api/core", () => ({ invoke, Channel: class {} }));

const { docOpen, docRead, docClose, docRefresh, readDoc } = await import("./daemon");

beforeEach(() => invoke.mockClear());

describe("doc IPC verbs map to their own Tauri commands", () => {
  // Name AND payload. The verb-list case below reads only calls[i][0], so this is
  // the sole assertion on the argument shape `doc_refresh` receives — not a
  // duplicate of it.
  it("docRefresh sends doc_refresh with a bare path payload", async () => {
    await docRefresh("/tmp/a.md");
    expect(invoke).toHaveBeenCalledWith("doc_refresh", { path: "/tmp/a.md" });
  });

  // The whole verb set, so a swap in either direction is caught, not just into
  // doc_refresh. Each name must match a #[tauri::command] fn in commands.rs.
  it("each doc verb uses a distinct command name", async () => {
    await docOpen("/tmp/a.md");
    await docRead("/tmp/a.md");
    await docClose("/tmp/a.md");
    await docRefresh("/tmp/a.md");
    await readDoc("/tmp/a.md");
    expect(invoke.mock.calls.map((c) => c[0])).toEqual([
      "doc_open",
      "doc_read",
      "doc_close",
      "doc_refresh",
      "read_doc",
    ]);
  });
});
