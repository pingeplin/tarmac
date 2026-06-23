// Port of TarmacKit/DocStore.swift — the app-side mirror of the daemon's doc
// registry: dock order, per-doc state, and ⌘P recency. Mutated only from daemon
// messages (plus the optimistic local `markRead`); observers get plain callbacks.
//
// The Swift `@MainActor class DocStore` becomes a plain TS class; the display
// derivations that lived as `RestoreDoc` computed properties become standalone
// functions over `RestoreDoc`. NSString path ops (lastPathComponent /
// deletingLastPathComponent) are replaced by tiny pure '/'-separated helpers so
// this runs in any environment (no node:path dependency).

/// The doc entry of docs/protocol.md "M1 subset" (wire DocEntry): nested in
/// `restore.docs[]`, flattened into `doc_opened`. Optional keys are absent on the
/// wire when missing — modelled here as optional fields (`undefined`).
export interface RestoreDoc {
  path: string;
  via: string;
  repo?: string;
  repoRoot?: string;
  repoColor?: number;
  read: boolean;
  lastChangedMs?: number;
  lastOpenedMs?: number;
  /// v4 Phase 3 additive (missing ⇒ undefined): the term that opened the doc
  /// (provenance + gravity owner).
  termId?: string;
}

/// One index group (crib-dock-index §2.3): first-appearance order, items in
/// dock order.
export interface DocGroup {
  key: string;
  name: string;
  colorIndex?: number;
  docs: RestoreDoc[];
}

// MARK: - Path helpers (replace NSString lastPathComponent / deletingLastPathComponent)

/// Final path segment, mirroring NSString.lastPathComponent over '/'-separated
/// paths. A trailing slash is dropped first; "/" maps to "/" and "" to "".
function basename(path: string): string {
  if (path === "") return "";
  // Drop a single trailing slash (NSString treats "/a/b/" like "/a/b").
  let p = path;
  while (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1);
  if (p === "/") return "/";
  const slash = p.lastIndexOf("/");
  return slash < 0 ? p : p.slice(slash + 1);
}

/// Parent directory, mirroring NSString.deletingLastPathComponent over
/// '/'-separated paths: "/a/b.md" -> "/a", "/a" -> "/", "a" -> "".
function dirname(path: string): string {
  if (path === "") return "";
  let p = path;
  while (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1);
  if (p === "/") return "/";
  const slash = p.lastIndexOf("/");
  if (slash < 0) return "";
  if (slash === 0) return "/";
  return p.slice(0, slash);
}

// MARK: - Display/grouping derivations
//
// Per docs/archive/m1/crib-state.md §1.1 / §4.1: when the daemon sent no repo,
// fall back to the parent directory exactly as M0 did so existing colors and
// paths do not shift.

export function fileName(doc: RestoreDoc): string {
  return basename(doc.path);
}

export function displayRepoName(doc: RestoreDoc): string {
  return doc.repo ?? basename(dirname(doc.path));
}

export function repoRelativePath(doc: RestoreDoc): string {
  const root = doc.repoRoot;
  if (root !== undefined && doc.path.startsWith(root + "/")) {
    return doc.path.slice(root.length + 1);
  }
  return fileName(doc);
}

export function displayPath(doc: RestoreDoc): string {
  return displayRepoName(doc) + "/" + repoRelativePath(doc);
}

/// Grouping identity (crib §1.1): repo_root when present, else the parent
/// directory path — never the name, so two repos both named `api` stay apart.
export function groupKey(doc: RestoreDoc): string {
  return doc.repoRoot ?? dirname(doc.path);
}

/// ⌘P recency seed (crib §6): latest of open and change.
export function recencyKey(doc: RestoreDoc): number {
  return Math.max(doc.lastOpenedMs ?? 0, doc.lastChangedMs ?? 0);
}

/// "Recently changed" window (crib-state §3): within 30 s of the last file event.
export const RECENT_WINDOW_MS = 30_000;

export function isRecent(lastChangedMs: number | undefined, nowMs: number): boolean {
  if (lastChangedMs === undefined) return false;
  return nowMs < lastChangedMs || nowMs - lastChangedMs < RECENT_WINDOW_MS;
}

export function groups(docs: RestoreDoc[]): DocGroup[] {
  const order: string[] = [];
  const byKey = new Map<string, DocGroup>();
  for (const doc of docs) {
    const key = groupKey(doc);
    const existing = byKey.get(key);
    if (existing) {
      existing.docs.push(doc);
    } else {
      order.push(key);
      const group: DocGroup = { key, name: displayRepoName(doc), docs: [doc] };
      // Mirror Swift's `colorIndex: doc.repoColor` (nil ⇒ key absent / undefined).
      if (doc.repoColor !== undefined) group.colorIndex = doc.repoColor;
      byKey.set(key, group);
    }
  }
  // order entries are exactly the keys present in byKey, so no compaction drops.
  return order.map((k) => byKey.get(k)!);
}

/// Index row labels: basename, falling back to the repo-relative path for
/// basename collisions within the group (crib-dock-index §2.3 DECISION).
export function itemLabels(group: DocGroup): string[] {
  const counts = new Map<string, number>();
  for (const doc of group.docs) {
    const name = fileName(doc);
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  return group.docs.map((doc) =>
    counts.get(fileName(doc)) === 1 ? fileName(doc) : repoRelativePath(doc),
  );
}

/// App-side mirror of the daemon's doc registry. `docs[]` order is the dock
/// order (protocol: normative in M1).
export class DocStore {
  private _docs: RestoreDoc[] = [];
  private indexByPath = new Map<string, number>();

  /// Monotonic per-doc recency: bumped by doc_opened/file_event, seeded from
  /// restore by sorting on recencyKey (ties broken by dock order) so a live bump
  /// always outranks restored history.
  private recencyTicks = new Map<string, number>();
  private nextTick = 1;

  /// Membership, order, or per-doc state changed.
  onChange?: () => void;
  /// A file_event landed for a registered doc (pulse trigger — fires after
  /// onChange so observers see the updated lastChangedMs).
  onFileChange?: (path: string) => void;

  get docs(): RestoreDoc[] {
    return this._docs;
  }

  get isEmpty(): boolean {
    return this._docs.length === 0;
  }

  doc(forPath: string): RestoreDoc | undefined {
    const i = this.indexByPath.get(forPath);
    return i === undefined ? undefined : this._docs[i];
  }

  /// ⌘P target; undefined with an empty registry. Argmax over recency ticks; a
  /// tie (>=) lets the later dock doc win.
  get mostRecentPath(): string | undefined {
    let best: { path: string; tick: number } | undefined;
    for (const doc of this._docs) {
      const tick = this.recencyTicks.get(doc.path) ?? 0;
      if (best === undefined || tick >= best.tick) {
        best = { path: doc.path, tick };
      }
    }
    return best?.path;
  }

  /// ⌘P focus-ladder helper: the most-recent doc among `candidates` (highest
  /// recency tick), or undefined if none are registered. Walks `docs` (dock
  /// order) so an unregistered/stale owner path is skipped and the tie-break
  /// matches `mostRecentPath`.
  mostRecentPathAmong(candidates: string[]): string | undefined {
    const set = new Set(candidates);
    let best: { path: string; tick: number } | undefined;
    for (const doc of this._docs) {
      if (!set.has(doc.path)) continue;
      const tick = this.recencyTicks.get(doc.path) ?? 0;
      if (best === undefined || tick >= best.tick) {
        best = { path: doc.path, tick };
      }
    }
    return best?.path;
  }

  /// `docs[]` order is the dock order. Dedupes by path (first wins), reseeds
  /// recency by sorting on recencyKey (ties broken by dock order).
  applyRestore(entries: RestoreDoc[]): void {
    const seen = new Set<string>();
    this._docs = entries.filter((d) => {
      if (seen.has(d.path)) return false;
      seen.add(d.path);
      return true;
    });
    this.reindex();
    this.recencyTicks = new Map();
    this.nextTick = 1;
    // Sort (index, doc) by recencyKey, ties by original dock offset, then bump
    // in that order so the highest recencyKey gets the highest tick.
    const seeded = this._docs.map((doc, offset) => ({ doc, offset }));
    seeded.sort((a, b) => {
      const ka = recencyKey(a.doc);
      const kb = recencyKey(b.doc);
      return ka === kb ? a.offset - b.offset : ka - kb;
    });
    for (const { doc } of seeded) this.bump(doc.path);
    this.onChange?.();
  }

  /// New docs append; re-opens update in place and never move the dock slot
  /// (crib-dock-index §1.3). Returns true when the doc is new.
  applyDocOpened(doc: RestoreDoc): boolean {
    let isNew: boolean;
    const i = this.indexByPath.get(doc.path);
    if (i !== undefined) {
      this._docs[i] = doc;
      isNew = false;
    } else {
      this._docs.push(doc);
      this.indexByPath.set(doc.path, this._docs.length - 1);
      isNew = true;
    }
    this.bump(doc.path);
    this.onChange?.();
    return isNew;
  }

  applyFileEvent(path: string, mtimeMs: number): void {
    const i = this.indexByPath.get(path);
    if (i === undefined) return;
    this._docs[i].lastChangedMs = mtimeMs;
    this.bump(path);
    this.onChange?.();
    this.onFileChange?.(path);
  }

  /// Optimistic local flip; the daemon is persisted via doc_read separately.
  markRead(path: string): void {
    const i = this.indexByPath.get(path);
    if (i === undefined || this._docs[i].read) return;
    this._docs[i].read = true;
    this.onChange?.();
  }

  private reindex(): void {
    this.indexByPath = new Map();
    this._docs.forEach((doc, i) => this.indexByPath.set(doc.path, i));
  }

  private bump(path: string): void {
    this.recencyTicks.set(path, this.nextTick);
    this.nextTick += 1;
  }
}
