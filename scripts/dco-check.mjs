#!/usr/bin/env node
// DCO sign-off tripwire. CONTRIBUTING.md has required a Developer Certificate of
// Origin sign-off since the repo was opened, but nothing ever checked it: of the
// first 128 commits exactly one carried a `Signed-off-by` — 9c23b85, the commit
// that added CONTRIBUTING.md itself. A rule nobody enforces is a rule the
// history cannot later be made to support, so this makes it mechanical.
//
// Deliberately narrow, matching docs-check.mjs: it compares strings, it never
// judges intent.
//   - merge commits are skipped (the DCO applies to authored work);
//   - a sign-off must match the commit's author or committer email, which is what
//     "you are certifying your own contribution" means in practice;
//   - the check is per-commit, because that is where the trailer must live for it
//     to survive into main (this repo squashes with COMMIT_MESSAGES, so each
//     commit's trailers are concatenated into the squashed body).
//
// Usage:
//   node scripts/dco-check.mjs                # origin/main..HEAD
//   node scripts/dco-check.mjs --base <ref>   # <ref>..HEAD  (CI passes the PR base)

import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
// stderr ignored: git's own "fatal: bad revision" would print before our own
// message and bury it. The catch below says the useful thing.
const git = (...args) =>
  execFileSync("git", args, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });

const flag = process.argv.indexOf("--base");
const base = flag !== -1 && process.argv[flag + 1] ? process.argv[flag + 1] : "origin/main";

let range;
try {
  range = git("rev-list", "--no-merges", `${base}..HEAD`).trim().split("\n").filter(Boolean);
} catch {
  console.error(`dco-check: cannot resolve "${base}..HEAD" — fetch the base ref first`);
  process.exit(2);
}

if (range.length === 0) {
  console.log(`dco-check: ok (no commits in ${base}..HEAD)`);
  process.exit(0);
}

// One trailer per line. Anchored hard at column zero on purpose: `^\s*` would
// also match a trailer quoted inside an indented code block, so a commit that
// merely *documents* the sign-off format would pass as signed — which is exactly
// what a commit touching CONTRIBUTING.md looks like. `[^<\n]*` (not `.+`) keeps
// the capture on the FIRST bracket pair, so a second address cannot displace the
// real signer.
const SIGNOFF = /^Signed-off-by:[^<\n]*<([^>]+)>\s*$/gim;
const ANY_SIGNOFF = /^Signed-off-by:/im;

const failures = [];
for (const sha of range) {
  // NUL-separated, not line-positional: an empty identity field (git lets you
  // commit with user.email="") would otherwise slide every later field up one.
  const [author, committer, name, body] = git(
    "show", "-s", "--format=%ae%x00%ce%x00%an%x00%B", sha,
  ).split("\0");

  const signed = [...(body ?? "").matchAll(SIGNOFF)].map((m) => m[1].trim().toLowerCase());
  const identities = [author, committer].map((e) => e.trim().toLowerCase()).filter(Boolean);

  if (!signed.some((e) => identities.includes(e))) {
    const subject = git("show", "-s", "--format=%s", sha).trim();
    const expected = `    expected: Signed-off-by: ${name} <${author}>`;
    let why;
    if (signed.length > 0) {
      why = `    signed by ${signed.join(", ")} — none matches the author (${author})`;
    } else if (ANY_SIGNOFF.test(body ?? "")) {
      // Distinguishing these matters: "amend with -s" is the wrong advice when
      // the trailer is there but malformed.
      why = "    a Signed-off-by line is present but is malformed — expected exactly one <email>";
    } else {
      why = "    no Signed-off-by trailer";
    }
    failures.push(`${sha.slice(0, 7)} ${subject}\n${why}\n${expected}`);
  }
}

if (failures.length) {
  console.error(`dco-check: ${failures.length} of ${range.length} commit(s) not signed off\n`);
  for (const f of failures) console.error(`  ${f}\n`);
  console.error("Add the trailer with `git commit -s`, or to fix the last commit:");
  console.error("  git commit --amend -s --no-edit\n");
  console.error("See CONTRIBUTING.md — signing off certifies you have the right to submit the change.");
  process.exit(1);
}

console.log(`dco-check: ok (${range.length} commit(s) signed off)`);
