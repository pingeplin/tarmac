import assert from "node:assert/strict";
import { test } from "node:test";

import { killsTarmacByName } from "./kill-guard.mjs";

// The guard's contract is this list and the cases in hook.test.mjs: a form is
// read when a test here says so, and spec 2611.0031 lists what is not read.

// Each wrapper with the ways its own arguments can stand before the command.
const WRAPPED = {
  sudo: ["", "-n", "-E", "-u root", "-u root -E", "--user root", "--user=root", "-g staff -u root", "--", "-n --", "A=1", "-u root A=1 B=2"],
  doas: ["", "-n", "-u root", "-C conf"],
  env: ["", "-i", "-u X", "--unset X", "A=1", "-i A=1 B=2", "-C dir", "--"],
  nice: ["", "-n 5", "-n5", "--adjustment 5", "--adjustment=5", "-5"],
  timeout: ["5", "5s", "-s KILL 5", "-s kill 5", "--signal KILL 5", "--signal=KILL 5", "-k 1 5", "--kill-after 1 5", "--foreground 5", "-s TERM -k 1 5"],
  caffeinate: ["", "-i", "-t 60", "-w 123", "-dims"],
  xargs: ["", "-0", "-r", "-n 1", "-n1", "-I {}", "-I{}", "-L 1", "-P 4", "-0 -n 1", "-J %", "--max-args 1", "--max-args=1"],
  time: ["", "-p", "-o out", "-f fmt"],
  exec: ["", "-a name", "-c", "-l"],
  command: ["", "-p", "--"],
  builtin: [""],
  nohup: ["", "--"],
  noglob: [""],
  coproc: [""],
};
const prefixes = Object.entries(WRAPPED).flatMap(([wrapper, forms]) => forms.map((form) => `${wrapper} ${form}`.trim()));

test("every wrapper form before a kill by name is refused", () => {
  const passed = prefixes.flatMap((prefix) => ["pkill tarmacd", "pkill -9 -f tarmac-app", "killall TarmacApp", "/usr/bin/pkill tarmacd"].map((kill) => `${prefix} ${kill}`)).filter((line) => !killsTarmacByName(line));

  assert.deepEqual(passed, []);
});

test("every wrapper form before a program that only mentions a kill passes", () => {
  const refused = prefixes.flatMap((prefix) => ["grep -rn pkill tarmac/", "echo pkill tarmacd", "make kill-daemon", "ls tarmac"].map((rest) => `${prefix} ${rest}`)).filter(killsTarmacByName);

  assert.deepEqual(refused, []);
});

test("two wrappers in a row are both passed over", () => {
  const pairs = ["sudo -u root env A=1", "nohup sudo -n", "env -i nice -n 5", "sudo timeout -s KILL 5", "time -p sudo --", "exec env -u X", "command sudo"];

  assert.deepEqual(pairs.filter((pair) => !killsTarmacByName(`${pair} pkill tarmacd`)), []);
  assert.deepEqual(pairs.filter((pair) => killsTarmacByName(`${pair} grep pkill tarmac/`)), []);
});

test("every wrapper form before a shell that kills by name is refused", () => {
  const passed = prefixes.filter((prefix) => !prefix.startsWith("xargs")).filter((prefix) => !killsTarmacByName(`${prefix} sh -c 'pkill tarmacd'`));

  assert.deepEqual(passed, []);
});

test("a kill of what a search by name found is refused in each form; a kill that only asks, or of a pid, passes", () => {
  const refused = [
    "kill $(pgrep tarmacd)",
    "kill -9 $(pgrep -f tarmac-app)",
    "kill `pidof tarmacd`",
    'kill "$(pgrep tarmacd)"',
    "kill -TERM -- $(pgrep -x TarmacApp)",
    "sudo kill $(pgrep tarmacd)",
    "kill $(sudo -n pgrep tarmacd)",
    "kill $(env pgrep tarmacd)",
    "pgrep tarmacd | xargs kill",
    "pgrep -f tarmac-app | xargs -n 1 kill -9",
    "pgrep tarmacd | xargs -r kill",
    "pgrep tarmacd | sudo xargs kill",
  ];
  const passes = ["kill 1234", 'kill -0 "$pid"', "kill -0 $(pgrep -x tarmacd)", "kill $(cat .dev/pid)", "lsof -t .dev/tarmacd.sock | xargs kill", "pgrep -fl tarmacd", "echo $(pgrep tarmacd)", "kill $(pgrep nginx)", "ps aux | grep -i tarmac"];

  assert.deepEqual(refused.filter((line) => !killsTarmacByName(line)), []);
  assert.deepEqual(passes.filter(killsTarmacByName), []);
});

test("`command -v` asks and runs nothing; `command` before a kill runs it", () => {
  assert.deepEqual(["command -v pkill tarmacd", "command -V pkill tarmacd", "command -p -v pkill tarmacd", "command -pv pkill tarmacd"].filter(killsTarmacByName), []);
  assert.deepEqual(["command pkill -v tarmacd", "command -p pkill tarmacd", "command pkill -V -f tarmac"].filter((line) => !killsTarmacByName(line)), []);
});

// The body of a commit message or of a pull request, as an agent sends it.
const BODY = "It refuses `pkill tarmacd` and\npkill -f tarmac-app\n$(pkill tarmacd) and (killall Tarmac) \\\nkill $(pgrep tarmacd)";

test("text that an agent sends as data is not a command", () => {
  const lines = [
    `git commit -s -m "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `gh pr create --title x --body "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `cat > notes.md <<'EOF'\n${BODY}\nEOF`,
    `cat > notes.md <<EOF\nplain text: pkill tarmacd\nEOF`,
    `cat <<-'EOF' > x\n\t${BODY}\n\tEOF\nls`,
    `python3 - <<'PY'\ns = "pkill tarmacd"\nprint(s)\nPY`,
    "node -e 'console.log(\"pkill tarmacd\")'",
    `python3 -c "print('killall TarmacApp')"`,
    'grep -rn "pkill tarmacd" .',
    "rg 'killall|pkill' scripts/ tarmac/",
    "git log --grep='pkill tarmacd'",
    "sed -n '/pkill tarmacd/p' CLAUDE.md",
    'echo "never pkill tarmacd"',
    "echo never pkill tarmacd",
    "ls # pkill tarmacd",
    "cd tarmac && make kill-daemon",
    "make kill-daemon DEV_DIR=.dev2",
  ];

  assert.deepEqual(lines.filter(killsTarmacByName), []);
});

test("a kill by name after data, on its own line or in the same one, is refused", () => {
  const lines = [
    `cat > notes.md <<'EOF'\n${BODY}\nEOF\npkill tarmacd`,
    `git commit -m "$(cat <<'EOF'\n${BODY}\nEOF\n)" && pkill tarmacd`,
    'echo "never pkill tarmacd"; killall tarmacd',
    "grep x <<< tarmac\npkill tarmacd",
    "ls # a comment\npkill tarmacd",
    "cd x && \\\n  pkill -f tarmac",
  ];

  assert.deepEqual(lines.filter((line) => !killsTarmacByName(line)), []);
});

test("text that cannot be read throws nothing, and what is too deep is judged by its words", () => {
  const broken = ['echo "unclosed pkill tarmacd', "echo 'unclosed", "echo `unclosed", "echo $(unclosed", "cat <<EOF\nno end", "ls \\", "((((", "))))", "<<", "<<<", "$'", ""];
  const deep = (open, tail) => `${open.repeat(10000)}${tail}`;

  assert.deepEqual(broken.map(killsTarmacByName), broken.map(() => false));
  assert.deepEqual(["$(", "(", "`", "eval "].map((open) => killsTarmacByName(deep(open, "pkill tarmacd"))), [true, true, true, true]);
  assert.deepEqual(["$(", "(", "eval "].map((open) => killsTarmacByName(deep(open, "ls"))), [false, false, false]);
});

test("an `eval` is followed 20 deep; one more and the words alone decide", () => {
  const said = (depth) => `${"eval ".repeat(depth)}echo pkill tarmacd`;

  assert.equal(killsTarmacByName(said(20)), false);
  assert.equal(killsTarmacByName(said(21)), true);
});

// Decision 8's table: each wrapper's flags that take a value in the next word.
const VALUED = {
  sudo: ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t", "--user", "--group", "--host", "--prompt", "--chdir"],
  doas: ["-u", "-C"],
  env: ["-u", "-C", "-P", "--unset", "--chdir"],
  nice: ["-n", "--adjustment"],
  timeout: ["-s", "-k", "--signal", "--kill-after"],
  caffeinate: ["-t", "-w"],
  xargs: ["-n", "-I", "-L", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S", "--max-args", "--max-procs", "--replace", "--delimiter"],
  time: ["-o", "-f"],
  exec: ["-a"],
};

test("the value of each flag in the table is not taken for the program", () => {
  const prefixes = Object.entries(VALUED).flatMap(([wrapper, flags]) => flags.map((flag) => `${wrapper} ${flag} ls${wrapper === "timeout" ? " 5" : ""}`));

  assert.deepEqual(prefixes.filter((prefix) => !killsTarmacByName(`${prefix} pkill tarmacd`)), []);
  assert.deepEqual(prefixes.filter((prefix) => killsTarmacByName(`${prefix} grep pkill tarmac/`)), []);
});

test("a redirection or an assignment after the duration of `timeout` is passed over", () => {
  const lines = ["timeout 5 2>/dev/null pkill tarmacd", "timeout 5 >/dev/null pkill tarmacd", "timeout 5 2> /dev/null pkill tarmacd", "timeout 5 A=1 pkill tarmacd"];

  assert.deepEqual(lines.filter((line) => !killsTarmacByName(line)), []);
  assert.equal(killsTarmacByName("timeout 5 2>/dev/null grep pkill tarmac/"), false);
});

test("each keyword and each shell before a kill by name is refused", () => {
  const lines = [
    "if pkill tarmacd; then :; fi",
    "if :; then pkill tarmacd; fi",
    "if :; then :; elif pkill tarmacd; then :; fi",
    "if :; then :; else pkill tarmacd; fi",
    "while pkill tarmacd; do :; done",
    "until pkill tarmacd; do :; done",
    "while :; do pkill tarmacd; done",
    "! pkill tarmacd",
    "{ pkill tarmacd; }",
    ...["sh", "bash", "zsh", "dash", "/bin/zsh"].map((shell) => `${shell} -c 'pkill tarmacd'`),
  ];

  assert.deepEqual(lines.filter((line) => !killsTarmacByName(line)), []);
});

test("`&>`, `>&` and `2>&1` end no command, and a `#` inside a word starts no comment", () => {
  assert.deepEqual(["echo x &>/dev/null pkill tarmacd", "echo x 2>&1 pkill tarmacd", "echo x >& /dev/null pkill tarmacd"].filter(killsTarmacByName), []);
  assert.deepEqual([">& /dev/null pkill tarmacd", "&>/dev/null pkill tarmacd", "echo a#b; pkill tarmacd"].filter((line) => !killsTarmacByName(line)), []);
});

test("text too deep to read is refused only when it holds a word of such a kill and the name", () => {
  const deep = (tail) => `${"eval ".repeat(25)}${tail}`;

  assert.deepEqual(["pkill tarmacd", "killall tarmacd", "PKILL TARMACD", "kill $(pgrep tarmacd)", "kill $(pidof tarmacd)"].filter((tail) => !killsTarmacByName(deep(tail))), []);
  assert.deepEqual(["pkill nginx", "ls tarmac", "kill 123"].filter((tail) => killsTarmacByName(deep(tail))), []);
});
