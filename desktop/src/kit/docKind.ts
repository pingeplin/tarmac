// Doc-kind routing + tarmac-card:// addressing for HTML doc cards (spec
// 2607.0004). Kind is derived from the path extension, never stored — the
// DocCardModel and wire protocol know nothing about it.

export type DocKind = "markdown" | "html";

// Extension check, case-insensitive. Dotfiles (".html") and trailing-dot names
// have no extension → markdown, matching Node path.extname semantics.
export function docKind(path: string): DocKind {
  const base = path.slice(path.lastIndexOf("/") + 1);
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return "markdown";
  const ext = base.slice(dot + 1).toLowerCase();
  return ext === "html" || ext === "htm" ? "html" : "markdown";
}

// The whole absolute path is one percent-encoded segment under the "doc" host;
// ?v= is a cache-buster only (the Rust handler ignores it and serves current
// bytes) — bumping it on file_event is what forces the iframe reload.
export function cardSrcUrl(path: string, mtimeMs: number | undefined): string {
  return `tarmac-card://doc/${encodeURIComponent(path)}?v=${mtimeMs ?? 0}`;
}
