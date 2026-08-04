#!/usr/bin/env node
// Tier-1 doc drift tripwires. Deterministic only — every rule here either passes
// or names a file:line you can go fix. Nothing is inferred, nothing is stylistic.
//
// The rules exist because docs rot in exactly four mechanical ways, all of which
// happened in this repo before this script did:
//   1. a doc gets added with no ACTIVE/PROPOSED/HISTORICAL banner, so readers
//      (human or agent) can't tell whether it describes `main`;
//   2. a doc moves and inbound links rot;
//   3. an ACTIVE doc cites a source path that was renamed or deleted (this is how
//      `app/Sources/…` and `DocTemplate.html` survived the Swift → Tauri rebuild);
//   4. a wire message ships without reaching the architecture/protocol tables
//      (TermClose and DocClose both did).
//
// Prose staleness is NOT in scope — no rule here reads meaning. Only ACTIVE docs
// are held to rules 3; HISTORICAL docs are frozen records and are *supposed* to
// name things that no longer exist.
//
// Usage:
//   node scripts/docs-check.mjs                  # the blocking rules (make docs-check)
//   node scripts/docs-check.mjs --deleted <ref>  # + advisory scan of files deleted since <ref>

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, normalize, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const sh = (...args) => execFileSync(args[0], args.slice(1), { cwd: ROOT, encoding: "utf8" });
const tracked = sh("git", "ls-files").split("\n").filter(Boolean);

const failures = [];
const notices = [];
const fail = (file, line, msg) => failures.push(`${file}:${line}: ${msg}`);

/** Every markdown doc under docs/, plus the two root docs that describe `main`. */
const docs = tracked.filter((p) => p.startsWith("docs/") && p.endsWith(".md"));
const rootDocs = ["README.md", "CLAUDE.md"];
const read = (p) => readFileSync(join(ROOT, p), "utf8");

// ---------------------------------------------------------------- rule 1: banner
// The banner is the whole point of the classification: it is what lets a reader
// know in one line whether a page may be cited as current behaviour.

const STATUSES = ["ACTIVE", "PROPOSED", "HISTORICAL"];
const BANNER = new RegExp(`Doc status:\\s*\\*{0,2}(${STATUSES.join("|")})`);
const statusOf = new Map();

for (const p of docs) {
  const head = read(p).split("\n").slice(0, 12).join("\n");
  const m = head.match(BANNER);
  if (!m) {
    fail(p, 1, `no "Doc status: <${STATUSES.join("|")}>" banner in the first 12 lines`);
    continue;
  }
  statusOf.set(p, m[1]);
}
// The root docs are ACTIVE by definition — they are the entry points.
for (const p of rootDocs) statusOf.set(p, "ACTIVE");

// ------------------------------------------------------------- rule 2: link rot
// Relative markdown links only; external URLs are not this script's business.

const LINK = /\[[^\]]*\]\(([^)\s]+)\)/g;

for (const p of [...docs, ...rootDocs]) {
  const lines = read(p).split("\n");
  lines.forEach((text, i) => {
    for (const m of text.matchAll(LINK)) {
      const target = m[1].split("#")[0];
      if (!target || /^(https?:|mailto:)/.test(target)) continue;
      if (!existsSync(join(ROOT, normalize(join(dirname(p), target))))) {
        fail(p, i + 1, `dead relative link → ${target}`);
      }
    }
  });
}

// -------------------------------------------------- rule 3: cited paths (ACTIVE)
// A backticked token that looks like a concrete file in this repo must resolve.
// Deliberately narrow so it never guesses:
//   - directory-shaped tokens (trailing "/") are skipped — build outputs like
//     desktop/src-tauri/target/ are gitignored and legitimately absent;
//   - glob/placeholder tokens ({a,b}, *, <id>) are skipped;
//   - a token rooted at a top-level dir must exist verbatim;
//   - a token with a source extension may be written relative (kit/foo.ts), so it
//     only has to be a path-boundary suffix of some tracked file.

const TOP = ["core/", "desktop/", "docs/", "scripts/", "packaging/", ".github/", ".blueprint/"];
const SRC_EXT = /\.(ts|tsx|rs|mjs|js|css|html|json|swift|sh|toml|rb)$/;
const CODE = /`([^`\n]+)`/g;
const suffixHit = (t) => tracked.some((f) => f === t || f.endsWith("/" + t));

for (const [p, status] of statusOf) {
  if (status !== "ACTIVE") continue;
  read(p).split("\n").forEach((text, i) => {
    for (const m of text.matchAll(CODE)) {
      const t = m[1].trim();
      if (!t.includes("/") || /[\s{}*?<>|()]/.test(t)) continue;
      if (t.endsWith("/") || t.startsWith("~") || t.startsWith("/") || /^\w+:/.test(t)) continue;
      if (TOP.some((d) => t.startsWith(d))) {
        if (!existsSync(join(ROOT, t))) fail(p, i + 1, `cites a path that does not exist: ${t}`);
      } else if (SRC_EXT.test(t) && !suffixHit(t)) {
        fail(p, i + 1, `cites a source file no tracked path ends with: ${t}`);
      }
    }
  });
}

// ------------------------------------------------- rule 4: wire messages ↔ docs
// The Msg enum is the contract. architecture.md's message table names variants in
// CamelCase; protocol.md names the on-wire snake_case "t" tag. A message that
// ships without landing in both is invisible to anyone reading the docs.

const PROTO_SRC = "core/crates/tarmac-protocol/src/lib.rs";
const enumBody = read(PROTO_SRC).match(/pub enum Msg \{\n([\s\S]*?)\n\}/);
if (!enumBody) {
  fail(PROTO_SRC, 1, "could not locate `pub enum Msg` — docs-check rule 4 cannot run");
} else {
  const variants = [...enumBody[1].matchAll(/^ {4}([A-Z][A-Za-z0-9]*)\s*(\{|,)/gm)]
    .map((m) => m[1])
    .filter((v) => v !== "Unknown"); // #[serde(other)] catch-all, never sent
  const snake = (v) => v.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
  const arch = read("docs/architecture.md");
  const proto = read("docs/protocol.md");
  for (const v of variants) {
    if (!new RegExp(`\\b${v}\\b`).test(arch)) {
      fail("docs/architecture.md", 1, `Msg::${v} exists on the wire but is absent from this doc`);
    }
    if (!proto.includes(snake(v))) {
      fail("docs/protocol.md", 1, `Msg::${v} ("${snake(v)}") exists on the wire but is absent from this doc`);
    }
  }
}

// ------------------------------------- advisory: files deleted since <ref>
// Not blocking. Deleting a component is the single most reliable way to make a
// doc lie (the shelf and DockPane both outlived their code in docs/). A basename
// still named by an ACTIVE doc is worth one look, not a red build.

const refFlag = process.argv.indexOf("--deleted");
if (refFlag !== -1 && process.argv[refFlag + 1]) {
  const ref = process.argv[refFlag + 1];
  let deleted = [];
  try {
    deleted = sh("git", "diff", "--diff-filter=D", "--name-only", `${ref}...HEAD`)
      .split("\n")
      .filter((f) => f && SRC_EXT.test(f));
  } catch {
    notices.push(`could not diff against ${ref} — skipping the deleted-file scan`);
  }
  for (const f of deleted) {
    const stem = f.split("/").pop().replace(SRC_EXT, "");
    if (stem.length < 4) continue;
    for (const [p, status] of statusOf) {
      if (status !== "ACTIVE") continue;
      const lines = read(p).split("\n");
      lines.forEach((text, i) => {
        if (new RegExp(`\\b${stem}\\b`).test(text)) {
          notices.push(`${p}:${i + 1}: still names \`${stem}\`, deleted in this change (${f})`);
        }
      });
    }
  }
}

// ------------------------------------------------------------------------ report

for (const n of notices) console.log(`notice: ${n}`);
if (failures.length) {
  console.error(`\ndocs-check: ${failures.length} problem(s)\n`);
  for (const f of failures) console.error(`  ${f}`);
  console.error("\nSee docs/README.md for what ACTIVE / PROPOSED / HISTORICAL mean.");
  process.exit(1);
}
console.log(`docs-check: ok (${statusOf.size} docs, ${notices.length} notice(s))`);
