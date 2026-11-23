import assert from "node:assert/strict";
import { test } from "node:test";

import "./test-env.mjs";

import { unpinnedLaunch } from "./launch-guard.mjs";
import { refuses } from "./shell-commands.mjs";

const launchesUnpinned = (line) => refuses(unpinnedLaunch, line);

// The rule's contract is this list and its cases in hook.test.mjs; the head of
// launch-guard.mjs lists what it does not read.

const PINS = "TARMAC_SOCKET=$PWD/.dev/rel/tarmacd.sock TARMAC_STATE=$PWD/.dev/rel/state.json TARMAC_CONFIG_DIR=$PWD/.dev/rel/config";

const LAUNCHES = [
  "open dist/Tarmac.app",
  "open ./dist/Tarmac.app/",
  'open "$PWD/dist/Tarmac.app"',
  "open dist/tarmac.app",
  "open -n dist/Tarmac.app",
  "open -W dist/Tarmac.app",
  "open -a dist/Tarmac.app README.md",
  "open dist/Tarmac.app --args --verbose",
  "open /Volumes/Tarmac/Tarmac.app",
  "open /Volumes/Tarmac/Applications/Tarmac.app",
  "open dist/Applications/Tarmac.app",
  "open /tmp/x/Applications/Tarmac.app",
  "dist/Applications/Tarmac.app/Contents/MacOS/tarmac-app",
  "open dist/Tarmac.app/Contents/MacOS/tarmac-app",
  "open file:///tmp/x/dist/Tarmac.app",
  "dist/Tarmac.app/Contents/MacOS/tarmac-app",
  "./dist/Tarmac.app/Contents/MacOS/tarmacd",
  '"/Volumes/Tarmac 1.0/Tarmac.app/Contents/MacOS/tarmac-app"',
  "core/target/release/tarmacd",
  "./core/target/release/tarmac open notes.md",
  "core/target/aarch64-apple-darwin/release/tarmacd",
  "core/target/release/deps/tarmacd-0123abcd",
  "app/.build/release/TarmacApp",
  "app/.build/arm64-apple-macosx/release/TarmacApp",
  "app/.build/release/tarmac-smoke",
  "app/.build/apple/Products/Release/TarmacApp",
  "core/target/release/tarmacd --version --verbose",
  "cargo run --release -p tarmacd",
  "cargo run -r --bin tarmacd",
  "cargo run --profile release --package tarmacd",
  "cargo run --profile=release --package=tarmacd",
  "cargo run --release --bin=tarmacd -- --flag",
  "cargo +stable run --release -p tarmacd",
  "rustup run stable cargo run --release -p tarmacd",
  "swift run -c release TarmacApp",
  "swift run -crelease TarmacApp",
  "swift run --configuration release tarmac-smoke",
  "swift run --configuration=release --package-path app TarmacApp",
];

test("each launch of a built app or a release binary with no pin is refused", () => {
  assert.deepEqual(LAUNCHES.filter((line) => !launchesUnpinned(line)), []);
});

test("each launch with all three pins in the same command passes", () => {
  assert.deepEqual(LAUNCHES.map((line) => `${PINS} ${line}`).filter(launchesUnpinned), []);
  assert.deepEqual(LAUNCHES.map((line) => `env ${PINS} ${line}`).filter(launchesUnpinned), []);
});

test("a launch with two of the three pins, or a pin with an empty value, is refused", () => {
  const pins = PINS.split(" ");
  const twoOfThree = pins.map((_, left) => pins.filter((__, i) => i !== left).join(" "));
  const lines = [
    ...twoOfThree.map((two) => `${two} open dist/Tarmac.app`),
    ...twoOfThree.map((two) => `env ${two} core/target/release/tarmacd`),
    `TARMAC_SOCKET= ${pins.slice(1).join(" ")} open dist/Tarmac.app`,
    `${PINS} TARMAC_CONFIG_DIR= app/.build/release/TarmacApp`,
    'TARMAC_SOCKET="" TARMAC_STATE=s TARMAC_CONFIG_DIR=c open dist/Tarmac.app',
  ];

  assert.deepEqual(lines.filter((line) => !launchesUnpinned(line)), []);
});

test("pins on another command, or set and not exported, do not pin the launch", () => {
  const lines = [`${PINS} true; open dist/Tarmac.app`, `${PINS.replaceAll(" ", "; ")}; open dist/Tarmac.app`, `${PINS} make bundle && open dist/Tarmac.app`, `open dist/Tarmac.app; export ${PINS}`];

  assert.deepEqual(lines.filter((line) => !launchesUnpinned(line)), []);
});

test("pins given by export before it, by open --env, by a mix, or to a shell that launches pass", () => {
  const lines = [
    `export ${PINS}; open dist/Tarmac.app`,
    `export ${PINS} && core/target/release/tarmacd`,
    "open --env TARMAC_SOCKET=a --env TARMAC_STATE=b --env TARMAC_CONFIG_DIR=c dist/Tarmac.app",
    "TARMAC_SOCKET=a open --env TARMAC_STATE=b --env TARMAC_CONFIG_DIR=c dist/Tarmac.app",
    "TARMAC_SOCKET=a env TARMAC_STATE=b TARMAC_CONFIG_DIR=c core/target/release/tarmacd",
    `${PINS} sh -c 'open dist/Tarmac.app'`,
    `${PINS} bash -lc "core/target/release/tarmac open x.md"`,
    `${PINS} eval open dist/Tarmac.app`,
    `nohup env ${PINS} dist/Tarmac.app/Contents/MacOS/tarmac-app &`,
  ];

  assert.deepEqual(lines.filter(launchesUnpinned), []);
});

test("the release CLI reads only TARMAC_SOCKET: that pin alone is enough for it, and nothing less", () => {
  const pinned = [
    "env -u TARMAC_TERM_ID TARMAC_SOCKET=$W/.dev/qa/tarmacd.sock $W/core/target/release/tarmac --version | tee out.txt",
    'bt() { env -u TARMAC_TERM_ID TARMAC_SOCKET=$D/tarmacd.sock $W/dist/Tarmac.app/Contents/MacOS/tarmac "$@"; }; bt open x.html',
    "TARMAC_SOCKET=s core/target/release/tarmac open notes.md",
    "TARMAC_SOCKET=s cargo run --release -p tarmac-cli -- open x.md",
    "TARMAC_SOCKET=s cargo run -r --bin tarmac -- open x.md",
  ];
  const unpinned = ["TARMAC_STATE=s TARMAC_CONFIG_DIR=c core/target/release/tarmac open x.md", "TARMAC_SOCKET= core/target/release/tarmac open x.md", "TARMAC_SOCKET=s core/target/release/tarmacd", "TARMAC_SOCKET=s core/target/release/deps/tarmac-0123abcd", "TARMAC_SOCKET=s open dist/Tarmac.app", "TARMAC_SOCKET=s cargo run --release -p tarmacd", "TARMAC_SOCKET=s swift run -c release TarmacApp"];

  assert.deepEqual(pinned.filter(launchesUnpinned), []);
  assert.deepEqual(unpinned.filter((line) => !launchesUnpinned(line)), []);
});

test("a launch behind a wrapper, a shell, a pipeline, a chain or a subshell is refused", () => {
  const lines = [
    "sudo open dist/Tarmac.app",
    "nohup dist/Tarmac.app/Contents/MacOS/tarmac-app &",
    "exec core/target/release/tarmacd",
    "env -i open dist/Tarmac.app",
    "time app/.build/release/TarmacApp",
    "timeout 5 core/target/release/tarmac open x.md",
    "sh -c 'open dist/Tarmac.app'",
    'bash -lc "core/target/release/tarmacd"',
    "core/target/release/tarmac open x.md | cat",
    "make bundle && open dist/Tarmac.app",
    "scripts/bundle.sh; open dist/Tarmac.app",
    "(cd dist && open Tarmac.app)",
    "echo $(core/target/release/tarmac open x.md)",
    "eval open dist/Tarmac.app",
    "if true; then open dist/Tarmac.app; fi",
    "cat <<EOF\nx\nEOF\nopen dist/Tarmac.app",
  ];

  assert.deepEqual(lines.filter((line) => !launchesUnpinned(line)), []);
});

test("a command that reads, signs, packs or builds those paths passes", () => {
  const lines = [
    "ls dist/Tarmac.app",
    "ls -la core/target/release/tarmacd",
    "cat dist/Tarmac.app/Contents/Info.plist",
    "codesign -dv --verbose=4 dist/Tarmac.app",
    "codesign --verify --deep --strict dist/Tarmac.app/Contents/MacOS/tarmac-app",
    "spctl -a -vv dist/Tarmac.app",
    "hdiutil create -srcfolder dist/Tarmac.app dist/Tarmac.dmg",
    "hdiutil attach dist/Tarmac.dmg",
    "cp -R dist/Tarmac.app /tmp/x",
    "rm -rf dist",
    "rm -rf dist/Tarmac.app",
    "scripts/bundle.sh",
    "make bundle",
    "make dmg VERSION=1.2.3",
    "make release VERSION=1.2.3",
    "stat core/target/release/tarmacd",
    "file core/target/release/tarmacd app/.build/release/TarmacApp",
    "otool -L app/.build/release/TarmacApp",
    "plutil -p dist/Tarmac.app/Contents/Info.plist",
    "xattr -cr dist/Tarmac.app",
    "ditto dist/Tarmac.app /tmp/x/Tarmac.app",
    "du -sh dist/Tarmac.app",
    "tar czf x.tgz dist/Tarmac.app",
    "zip -r x.zip dist/Tarmac.app",
    "test -x core/target/release/tarmacd",
    "[ -x core/target/release/tarmacd ]",
    "open -R dist/Tarmac.app",
    "open dist/Tarmac.dmg",
    "open dist",
    "cargo build --release",
    "swift build -c release",
    "make run",
    "make run DEV_DIR=$PWD/.dev/qa-x",
    "shasum -a 256 dist/Tarmac.dmg",
    "open https://github.com/x/y/releases/download/v1/Tarmac.app",
    "core/target/release/tarmacd --version",
    "dist/Tarmac.app/Contents/MacOS/tarmacd --version",
    "cargo run --release",
    "cargo run --release -p other-crate",
    "cargo run -p tarmacd",
    "cargo run --release -- -p tarmacd",
    "cargo build --release -p tarmacd",
    "swift run TarmacApp",
    "swift run -c debug TarmacApp",
    "swift run -c release",
    "swift build -c release --product TarmacApp",
  ];

  assert.deepEqual(lines.filter(launchesUnpinned), []);
});

test("the installed app is the user's own and passes; so does a debug build, on its own channel", () => {
  const lines = [
    "open /Applications/Tarmac.app",
    "open ~/Applications/Tarmac.app",
    'open "$HOME/Applications/Tarmac.app"',
    "open ${HOME}/Applications/Tarmac.app",
    "open /Users/someone/Applications/Tarmac.app",
    "open file:///Applications/Tarmac.app",
    "open -a /Applications/Tarmac.app notes.md",
    "/Applications/Tarmac.app/Contents/MacOS/tarmac-app",
    "core/target/debug/tarmacd",
    'TARMAC_DEV_SOCKET="$QA/tarmac-dev.sock" core/target/debug/tarmac dev snapshot',
    "app/.build/debug/TarmacApp",
    "app/.build/arm64-apple-macosx/debug/TarmacApp",
  ];

  assert.deepEqual(lines.filter(launchesUnpinned), []);
});

// The body of a commit message or of a pull request, as an agent sends it.
const BODY = "Never `open dist/Tarmac.app` bare;\nopen dist/Tarmac.app\n$(core/target/release/tarmacd) and (app/.build/release/TarmacApp) \\\ndist/Tarmac.app/Contents/MacOS/tarmac-app";

test("text that only mentions a launch is not one", () => {
  const lines = [
    `git commit -s -m "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `gh pr create --title x --body "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `cat > notes.md <<'EOF'\n${BODY}\nEOF`,
    'grep -rn "open dist/Tarmac.app" docs',
    "rg 'target/release/tarmacd' scripts/",
    "echo open dist/Tarmac.app",
    'echo "core/target/release/tarmacd"',
    "ls # open dist/Tarmac.app",
    "git log --grep='Tarmac.app'",
  ];

  assert.deepEqual(lines.filter(launchesUnpinned), []);
});

test("text too deep to read is refused only when it names such a path and lacks a pin", () => {
  const deep = (tail) => `${"eval ".repeat(25)}${tail}`;

  assert.deepEqual(["open dist/Tarmac.app", "core/target/release/tarmacd", "app/.build/release/TarmacApp"].filter((tail) => !launchesUnpinned(deep(tail))), []);
  assert.deepEqual([`${PINS} open dist/Tarmac.app`, "ls", "core/target/debug/tarmacd"].filter((tail) => launchesUnpinned(deep(tail))), []);
  assert.equal(launchesUnpinned(`${"$(".repeat(6000)}open dist/Tarmac.app`), true);
  assert.equal(launchesUnpinned(`${"$(".repeat(6000)}ls`), false);
});
