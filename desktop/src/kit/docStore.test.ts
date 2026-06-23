import { describe, it, expect } from "vitest";
import {
  DocStore,
  isRecent,
  groups,
  itemLabels,
  displayRepoName,
  repoRelativePath,
  displayPath,
  groupKey,
  type RestoreDoc,
} from "./docStore";

// Port of DocStoreTests.swift. The Swift test helper defaults via:"cli",
// read:false, everything else nil — mirrored here. Optional fields are simply
// omitted (undefined) rather than carrying explicit nils.
interface DocOpts {
  via?: string;
  repo?: string;
  repoRoot?: string;
  repoColor?: number;
  read?: boolean;
  lastChangedMs?: number;
  lastOpenedMs?: number;
}

function doc(path: string, opts: DocOpts = {}): RestoreDoc {
  const d: RestoreDoc = {
    path,
    via: opts.via ?? "cli",
    read: opts.read ?? false,
  };
  if (opts.repo !== undefined) d.repo = opts.repo;
  if (opts.repoRoot !== undefined) d.repoRoot = opts.repoRoot;
  if (opts.repoColor !== undefined) d.repoColor = opts.repoColor;
  if (opts.lastChangedMs !== undefined) d.lastChangedMs = opts.lastChangedMs;
  if (opts.lastOpenedMs !== undefined) d.lastOpenedMs = opts.lastOpenedMs;
  return d;
}

describe("DocStore", () => {
  // MARK: - Dock order

  it("restore order is dock order and deduped", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md"), doc("/r/b.md"), doc("/r/a.md"), doc("/r/c.md")]);
    expect(store.docs.map((d) => d.path)).toEqual(["/r/a.md", "/r/b.md", "/r/c.md"]);
  });

  it("doc_opened appends new and never moves existing", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md"), doc("/r/b.md")]);

    expect(store.applyDocOpened(doc("/r/c.md"))).toBe(true);
    expect(store.docs.map((d) => d.path)).toEqual(["/r/a.md", "/r/b.md", "/r/c.md"]);

    // Re-open updates in place, keeps the slot.
    expect(store.applyDocOpened(doc("/r/a.md", { read: false, lastOpenedMs: 99 }))).toBe(false);
    expect(store.docs.map((d) => d.path)).toEqual(["/r/a.md", "/r/b.md", "/r/c.md"]);
    expect(store.doc("/r/a.md")?.lastOpenedMs).toBe(99);
  });

  it("file_event for unregistered path is ignored", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md")]);
    let fired = false;
    store.onFileChange = () => {
      fired = true;
    };
    store.applyFileEvent("/r/ghost.md", 1);
    expect(store.docs.map((d) => d.path)).toEqual(["/r/a.md"]);
    expect(fired).toBe(false);
  });

  // MARK: - Recency (⌘P)

  it("empty store has no recent doc", () => {
    expect(new DocStore().mostRecentPath).toBeUndefined();
  });

  it("restore seeds recency from open and change times", () => {
    const store = new DocStore();
    store.applyRestore([
      doc("/r/a.md", { lastChangedMs: 500, lastOpenedMs: 100 }), // key 500
      doc("/r/b.md", { lastOpenedMs: 900 }), // key 900
      doc("/r/c.md", { lastOpenedMs: 200 }), // key 200
    ]);
    expect(store.mostRecentPath).toBe("/r/b.md");
  });

  it("restore recency ties break by dock order", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md"), doc("/r/b.md"), doc("/r/c.md")]);
    // All keys 0 (M0-era entries): the last dock doc wins.
    expect(store.mostRecentPath).toBe("/r/c.md");
  });

  it("doc_opened and file_event bump recency", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md", { lastOpenedMs: 100 }), doc("/r/b.md", { lastOpenedMs: 200 })]);

    store.applyDocOpened(doc("/r/a.md", { lastOpenedMs: 300 }));
    expect(store.mostRecentPath).toBe("/r/a.md");

    store.applyFileEvent("/r/b.md", 400);
    expect(store.mostRecentPath).toBe("/r/b.md");

    // A live bump outranks any restored timestamp.
    store.applyDocOpened(doc("/r/c.md"));
    expect(store.mostRecentPath).toBe("/r/c.md");
  });

  it("most-recent-among restricts to candidate set", () => {
    const store = new DocStore();
    store.applyRestore([
      doc("/r/a.md", { lastOpenedMs: 100 }),
      doc("/r/b.md", { lastOpenedMs: 900 }), // global winner
      doc("/r/c.md", { lastOpenedMs: 200 }),
    ]);
    // b is the global most-recent, but it is not a candidate: among {a, c}, c wins.
    expect(store.mostRecentPathAmong(["/r/a.md", "/r/c.md"])).toBe("/r/c.md");
    // The global winner still wins when it is in the set.
    expect(store.mostRecentPathAmong(["/r/a.md", "/r/b.md"])).toBe("/r/b.md");
  });

  it("most-recent-among follows live bumps", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md", { lastOpenedMs: 100 }), doc("/r/c.md", { lastOpenedMs: 200 })]);
    expect(store.mostRecentPathAmong(["/r/a.md", "/r/c.md"])).toBe("/r/c.md");
    store.applyDocOpened(doc("/r/a.md", { lastOpenedMs: 300 })); // live bump tops a
    expect(store.mostRecentPathAmong(["/r/a.md", "/r/c.md"])).toBe("/r/a.md");
  });

  it("most-recent-among is nil for empty or unregistered", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md")]);
    expect(store.mostRecentPathAmong([])).toBeUndefined();
    expect(store.mostRecentPathAmong(["/r/ghost.md"])).toBeUndefined();
  });

  // MARK: - Read transitions

  it("markRead flips once and notifies once", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md", { read: false })]);
    let changes = 0;
    store.onChange = () => {
      changes += 1;
    };

    store.markRead("/r/a.md");
    expect(store.doc("/r/a.md")?.read).toBe(true);
    expect(changes).toBe(1);

    store.markRead("/r/a.md"); // idempotent, no notification
    store.markRead("/r/none.md");
    expect(changes).toBe(1);
  });

  it("reopened doc carries daemon read state", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md", { read: true })]);
    // A cli re-open re-arms unread (daemon-decided; the entry is the truth).
    store.applyDocOpened(doc("/r/a.md", { read: false }));
    expect(store.doc("/r/a.md")?.read).toBe(false);
  });

  it("file_event does not touch read", () => {
    const store = new DocStore();
    store.applyRestore([doc("/r/a.md", { read: true })]);
    store.applyFileEvent("/r/a.md", 7);
    expect(store.doc("/r/a.md")?.read).toBe(true);
    expect(store.doc("/r/a.md")?.lastChangedMs).toBe(7);
  });

  // MARK: - Recent window

  it("isRecent boundary", () => {
    expect(isRecent(undefined, 1000)).toBe(false);
    expect(isRecent(1000, 1000 + 29_999)).toBe(true);
    expect(isRecent(1000, 1000 + 30_000)).toBe(false);
  });

  // MARK: - Display derivations

  it("display path inside repo", () => {
    const d = doc("/w/payments-api/docs/handoff.md", {
      repo: "payments-api",
      repoRoot: "/w/payments-api",
    });
    expect(displayRepoName(d)).toBe("payments-api");
    expect(repoRelativePath(d)).toBe("docs/handoff.md");
    expect(displayPath(d)).toBe("payments-api/docs/handoff.md");
    expect(groupKey(d)).toBe("/w/payments-api");
  });

  it("display path outside repo falls back to parent dir", () => {
    const d = doc("/Users/x/notes/todo.md");
    expect(displayRepoName(d)).toBe("notes");
    expect(displayPath(d)).toBe("notes/todo.md");
    expect(groupKey(d)).toBe("/Users/x/notes");
  });

  // MARK: - Index grouping

  it("groups by first appearance keeping dock order within", () => {
    const docs = [
      doc("/w/api/docs/a.md", { repo: "api", repoRoot: "/w/api", repoColor: 3 }),
      doc("/w/infra/run.md", { repo: "infra", repoRoot: "/w/infra", repoColor: 1 }),
      doc("/w/api/docs/b.md", { repo: "api", repoRoot: "/w/api", repoColor: 3 }),
    ];
    const g = groups(docs);
    expect(g.map((x) => x.name)).toEqual(["api", "infra"]);
    expect(g[0].docs.map((d) => d.path)).toEqual(["/w/api/docs/a.md", "/w/api/docs/b.md"]);
    expect(g[0].colorIndex).toBe(3);
  });

  it("two repos sharing a name group separately", () => {
    const docs = [
      doc("/w/one/api/a.md", { repo: "api", repoRoot: "/w/one/api" }),
      doc("/w/two/api/b.md", { repo: "api", repoRoot: "/w/two/api" }),
    ];
    expect(groups(docs).length).toBe(2);
  });

  it("item labels fall back to relative path on basename collision", () => {
    const group = groups([
      doc("/w/api/docs/plan.md", { repo: "api", repoRoot: "/w/api" }),
      doc("/w/api/archive/plan.md", { repo: "api", repoRoot: "/w/api" }),
      doc("/w/api/readme.md", { repo: "api", repoRoot: "/w/api" }),
    ])[0];
    expect(itemLabels(group)).toEqual(["docs/plan.md", "archive/plan.md", "readme.md"]);
  });
});
