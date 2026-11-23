import "./test-env.mjs";

import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after } from "node:test";

const dirs = [];
after(() => dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

/** A maker of scratch directories named `prefix…`, each removed when the test file ends. */
export const scratchIn =
  (fallback) =>
  (prefix = fallback) => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
    dirs.push(dir);
    return dir;
  };

/** Writes each `path: text` under `dir`; a `null` text is no file. */
export function write(dir, files) {
  for (const [path, text] of Object.entries(files)) {
    if (text === null) continue;
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
}

export const git = (dir, ...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });

/** `dir` as a git repository with no commit, in which the listed files are tracked. */
export function tracked(dir, files) {
  write(dir, files);
  git(dir, "init", "-q");
  git(dir, "add", "-A");
  return dir;
}

/** Runs a node script to its end. */
export function runScript(script, args, options) {
  const run = spawnSync(process.execPath, [script, ...args], { encoding: "utf8", ...options });
  return { code: run.status, out: run.stdout, err: run.stderr };
}

/** The `at` rows of a reporter's text, without the label. */
export const atRows = (text) =>
  text
    .split("\n")
    .filter((line) => /^ {2}(at| {2}) {3}/.test(line))
    .map((line) => line.slice(7));
/** The one row of a reporter's text with `label` (`why`, `fix`, `then`), without the label. */
export const rowOf = (text, label) => text.split("\n").find((line) => line.startsWith(`  ${label.padEnd(4)} `))?.slice(7);

/** The two wire codecs as the smallest tree that keeps arch-check's codec rule: one message, `ack`, in each. */
export const WIRE_CODECS = {
  "core/crates/tarmac-protocol/src/lib.rs": '#[serde(tag = "t", rename_all = "snake_case")]\npub enum Msg {\n    Ack,\n    #[serde(other)]\n    Unknown,\n}\n',
  "app/Sources/TarmacKit/Messages.swift": [
    "extension Message {",
    "    static func decode(_ value: MsgPackValue) -> Message {",
    "        switch t {",
    '        case "ack":',
    "            return .ack",
    "        }",
    "    }",
    "",
    "    func encodedValue() -> MsgPackValue {",
    '        Self.tagged("ack")',
    "    }",
    "}",
    "",
  ].join("\n"),
  "app/Tests/TarmacKitTests/MessagesTests.swift": "",
};
