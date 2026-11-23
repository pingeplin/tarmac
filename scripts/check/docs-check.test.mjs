import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";

import "./test-env.mjs";

import { docsCheck } from "../docs-check.mjs";
import { git, runScript, scratchIn, tracked, write } from "./test-support.mjs";

const scratch = scratchIn("docs-check-test-");
const banner = (status) => `# Doc\n\n> **Doc status: ${status}**\n\n`;
const INDEX = `${banner("ACTIVE")}[a](architecture.md) [p](protocol.md)\n`;

/** A git repository that breaks no rule, plus the listed files, all tracked. */
const repo = (files = {}) =>
  tracked(scratch(), {
    "README.md": "# Readme\n",
    "CLAUDE.md": "# Claude\n",
    "docs/README.md": INDEX,
    "docs/architecture.md": `${banner("ACTIVE")}Ping\n`,
    "docs/protocol.md": `${banner("ACTIVE")}ping\n`,
    "core/crates/tarmac-protocol/src/lib.rs": "pub enum Msg {\n    Ping,\n    #[serde(other)]\n    Unknown,\n}\n",
    ...files,
  });

const failures = (files) => docsCheck(repo(files), []).failures;

/** The script and the one module it imports, as files of a scratch tree. */
const script = (files) => ({
  "scripts/docs-check.mjs": readFileSync(join(import.meta.dirname, "../docs-check.mjs"), "utf8"),
  "scripts/check/git.mjs": readFileSync(join(import.meta.dirname, "git.mjs"), "utf8"),
  ...files,
});

test("a repository that breaks no rule has no failure and counts its docs", () => {
  assert.deepEqual(docsCheck(repo(), []), { failures: [], notices: [], count: 5 });
});

test("a doc without a status banner is a failure at its first line", () => {
  assert.deepEqual(failures({ "docs/x.md": "# X\n" }), ['docs/x.md:1: no "Doc status: <ACTIVE|PROPOSED|HISTORICAL>" banner in the first 12 lines']);
});

test("a relative link to no file is a failure; an anchor, a URL and a live link are not", () => {
  const index = `${INDEX}[a](architecture.md#top) [w](https://example.com/x) [m](mailto:a@b.c)\n[gone](gone.md)\n`;

  assert.deepEqual(failures({ "docs/README.md": index }), ["docs/README.md:7: dead relative link → gone.md"]);
});

test("an ACTIVE doc that cites a missing path is a failure; a HISTORICAL doc that does is not", () => {
  const files = {
    "docs/README.md": `${INDEX}\`scripts/gone.mjs\` \`kit/Gone.swift\` \`kit/Here.swift\`\n`,
    "app/kit/Here.swift": "",
    "docs/old.md": `${banner("HISTORICAL")}\`scripts/gone.mjs\`\n`,
  };

  assert.deepEqual(failures(files), ["docs/README.md:6: cites a path that does not exist: scripts/gone.mjs", "docs/README.md:6: cites a source file no tracked path ends with: kit/Gone.swift"]);
});

test("a Msg variant that a doc does not name is a failure of that doc", () => {
  const lib = "pub enum Msg {\n    Ping,\n    TermOpen { id: u32 },\n}\n";

  assert.deepEqual(failures({ "core/crates/tarmac-protocol/src/lib.rs": lib, "docs/protocol.md": `${banner("ACTIVE")}ping\n` }), [
    "docs/architecture.md:1: Msg::TermOpen exists on the wire but is absent from this doc",
    'docs/protocol.md:1: Msg::TermOpen ("term_open") exists on the wire but is absent from this doc',
  ]);
});

test("the script prints its failures in its own form and ends with 1, and ends with 0 when there is none", () => {
  const run = (dir) => runScript(join(dir, "scripts/docs-check.mjs"), [], { cwd: dir });

  assert.deepEqual(run(repo(script({}))), { code: 0, out: "docs-check: ok (5 docs, 0 notice(s))\n", err: "" });
  assert.deepEqual(run(repo(script({ "docs/README.md": `${INDEX}[gone](gone.md)\n` }))), {
    code: 1,
    out: "",
    err: "\ndocs-check: 1 problem(s)\n\n  docs/README.md:6: dead relative link → gone.md\n\nSee docs/README.md for what ACTIVE / PROPOSED / HISTORICAL mean.\n",
  });
});

test("an ACTIVE or PROPOSED doc that docs/README.md does not link to is a failure", () => {
  const files = { "docs/coding.md": `${banner("ACTIVE")}x\n`, "docs/proposed/idea.md": `${banner("PROPOSED")}x\n` };

  assert.deepEqual(failures(files), ["docs/coding.md:1: ACTIVE doc is not linked from docs/README.md", "docs/proposed/idea.md:1: PROPOSED doc is not linked from docs/README.md"]);
});

test("a link with an anchor or a ./ prefix links the doc", () => {
  const files = { "docs/README.md": `${INDEX}[c](./coding.md#rules) [i](proposed/idea.md)\n`, "docs/coding.md": `${banner("ACTIVE")}x\n`, "docs/proposed/idea.md": `${banner("PROPOSED")}x\n` };

  assert.deepEqual(failures(files), []);
});

test("a HISTORICAL doc needs no link; a PROPOSED record needs its own link, not its directory's", () => {
  const files = {
    "docs/README.md": `${INDEX}[designs](designs) [archive](archive/m0/)\n`,
    "docs/designs/2601.0001_built.md": `${banner("HISTORICAL")}x\n`,
    "docs/archive/m0/crib.md": `${banner("HISTORICAL")}x\n`,
    "docs/old.md": `${banner("HISTORICAL")}x\n`,
    "docs/designs/2601.0002_not_built.md": `${banner("PROPOSED")}x\n`,
  };

  assert.deepEqual(failures(files), ["docs/designs/2601.0002_not_built.md:1: PROPOSED doc is not linked from docs/README.md"]);
});

test("a skill that cites a missing path is a failure at its line", () => {
  const skill = "---\nname: s\n---\n\nRun `scripts/gone.sh`, then read `kit/Gone.swift`.\n";

  assert.deepEqual(failures({ ".claude/skills/s/SKILL.md": skill }), [
    ".claude/skills/s/SKILL.md:5: cites a path that does not exist: scripts/gone.sh",
    ".claude/skills/s/SKILL.md:5: cites a source file no tracked path ends with: kit/Gone.swift",
  ]);
});

test("a skill citing a live path, a placeholder, a glob, a directory, a URL or a command line is no failure", () => {
  const skill = ["`scripts/here.sh`", "`cd ../tarmac-worktrees/<N>-<slug>`", "`docs/designs/2606.0002_*`", "`dist/`", "`app/Vendor/`", "`docs/designs/<N>_x.md`", "`https://example.com/a.js`", "`swift scripts/gone.swift`", "`/start <N>`", "`~/.config/tarmac`", "`origin/main`"].join("\n");

  assert.deepEqual(failures({ ".claude/skills/s/SKILL.md": skill, "scripts/here.sh": "" }), []);
});

test("a gitignored path that is absent is no failure, in a skill or in an ACTIVE doc", () => {
  const files = { ".gitignore": "/core/target/\n", ".claude/skills/s/SKILL.md": "`core/target/debug/tarmacd`\n", "docs/README.md": `${INDEX}\`core/target/debug\`\n` };

  assert.deepEqual(failures(files), []);
});

test("a skill is not a classified doc: it needs no banner and does not change the count", () => {
  const dir = repo({ ".claude/skills/s/SKILL.md": "# S\n", ".claude/skills/s/notes.md": "`scripts/gone.sh`\n" });

  assert.deepEqual(docsCheck(dir, []), { failures: [], notices: [], count: 5 });
});

test("a PROPOSED doc that cites a missing path is no failure", () => {
  const files = { "docs/README.md": `${INDEX}[i](proposed/idea.md)\n`, "docs/proposed/idea.md": `${banner("PROPOSED")}\`scripts/gone.mjs\` \`kit/Gone.swift\`\n` };

  assert.deepEqual(failures(files), []);
});

test("an ignore file of the developer's own git does not hide a missing path", () => {
  const dir = repo({ "docs/README.md": `${INDEX}\`scripts/gone.mjs\`\n` });
  const home = scratch();
  write(home, { "excludes": "*.mjs\n", "gitconfig": `[core]\n\texcludesFile = ${join(home, "excludes")}\n` });
  const saved = process.env.GIT_CONFIG_GLOBAL;
  process.env.GIT_CONFIG_GLOBAL = join(home, "gitconfig");
  try {
    assert.deepEqual(docsCheck(dir, []).failures, ["docs/README.md:6: cites a path that does not exist: scripts/gone.mjs"]);
  } finally {
    if (saved === undefined) delete process.env.GIT_CONFIG_GLOBAL;
    else process.env.GIT_CONFIG_GLOBAL = saved;
  }
});

test("with --deleted, an ACTIVE doc that still names a deleted file is a notice, and without it nothing is", () => {
  const dir = repo({ "app/Sources/Widget.swift": "", "docs/architecture.md": `${banner("ACTIVE")}Ping and the Widget\n` });
  const commit = (message) => git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qam", message);
  commit("one");
  git(dir, "rm", "-q", "app/Sources/Widget.swift");
  commit("two");

  assert.deepEqual(docsCheck(dir, ["--deleted", "HEAD~1"]), { failures: [], notices: ["docs/architecture.md:5: still names `Widget`, deleted in this change (app/Sources/Widget.swift)"], count: 5 });
  assert.deepEqual(docsCheck(dir, []).notices, []);
});

test("importing the script runs no rule and prints nothing", () => {
  const dir = repo(script({ "docs/README.md": `${INDEX}[gone](gone.md)\n` }));
  const url = pathToFileURL(join(dir, "scripts/docs-check.mjs")).href;

  assert.deepEqual(runScript("--input-type=module", ["-e", `await import(${JSON.stringify(url)})`], { cwd: dir }), { code: 0, out: "", err: "" });
});

test("without docs/README.md, rule 5 is a failure that says it cannot run", () => {
  assert.deepEqual(failures({ "docs/README.md": null }), ["docs/README.md:1: missing — rule 5 cannot run"]);
});
