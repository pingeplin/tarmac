// A rule of the Bash hook: a built app or a release binary does not launch
// without its channel pinned. A release build resolves the installed channel:
// it attaches to the user's daemon and, on a version mismatch, SIGTERMs and
// replaces it. A launch is pinned when TARMAC_SOCKET, TARMAC_STATE and
// TARMAC_CONFIG_DIR (for the CLI `tarmac`, which reads only the first,
// TARMAC_SOCKET) each have a non-empty value in that command: its own
// `NAME=value` words, an `env`, `open --env`, an `export NAME=value` before it
// in the line, or the command that runs it (`sh -c`, `eval`).
//
// A launch is:
// - `open` on a `Tarmac.app` or its executable (not `open -R`, which only
//   shows it, and not a URL other than `file:`);
// - running the bundle's executable, or a binary named for Tarmac under a
//   `release` build directory of cargo or SwiftPM (`tarmacd --version` alone
//   prints and returns before it takes the socket);
// - `cargo run` with `--release`, `-r` or `--profile release` and a package
//   or binary named for Tarmac, and `swift run` with `-c release` and a
//   product named for Tarmac.
// The installed app (`/Applications/Tarmac.app`, or under `~`, `$HOME` or a
// `/Users/<name>` home) is the user's own and already on its channel; any
// other `Applications/Tarmac.app`, such as a mounted disk image's, is a launch.
// A debug build resolves a `dev/` channel of its own.
//
// It reads the line as shell-commands.mjs does. It does not see:
// - the value of a pin (a pin to the installed app's own socket passes);
// - `cargo run --release` that names no package or binary (it may run
//   another crate);
// - a launch by name (`open -a Tarmac`, `open -b`, `osascript … tell
//   application "Tarmac"`), a binary run from inside its directory
//   (`./tarmacd`), or a copy of the build under another name;
// - a binary given as an argument to a runner outside the reader's table
//   (`xcrun`, `launchctl submit`, `find -exec open`), or the name `xargs open`
//   reads from its input;
// - a pin that `env -i`, `sudo` (which resets the environment), `env -u`,
//   `unset` or `export -n` takes away after it is set, and the scope of a
//   subshell (an `export` in one pins what comes after).
// Refused although pinned, a safe failure: a pin assigned and then exported
// by name only (`A=x; export A`), `set -a`, and `declare -x`. Text nested too
// deep to read is judged by its words; the installed app and the CLI with only
// TARMAC_SOCKET are then refused too.

import { cargoSubcommand, ownArguments, pastRustupRun, programOf } from "./shell-commands.mjs";

const PINS = ["TARMAC_SOCKET", "TARMAC_STATE", "TARMAC_CONFIG_DIR"];
const SOCKET_ONLY = PINS.slice(0, 1);
const BUNDLE = /(^|\/)tarmac\.app\/?$/i;
const BUNDLE_EXECUTABLE = /(^|\/)tarmac\.app\/contents\/macos\/[^/]+$/i;
const INSTALLED = /^(~|\$HOME|\$\{HOME\}|\/Users\/[^/]+)?\/Applications\/tarmac\.app(\/|$)/i;
// `.build/apple/Products/Release/` is the place of a multi-arch SwiftPM build.
const RELEASE_BINARY = /(^|\/)(target|\.build)\/([^/]+\/){0,2}release\/(deps\/)?[^/]*tarmac[^/]*$/i;
const URL = /^[a-z][a-z0-9+.-]*:\/\//i;
const NAMES_TARMAC = /tarmac/i;

const built = (path, shapes) => shapes.some((shape) => shape.test(path)) && !INSTALLED.test(path);
const isCli = (name) => /^tarmac(-cli)?$/i.test(name);

/** The names `open --env NAME=value` gives a non-empty value. */
const openEnv = (args) => args.flatMap((arg, i) => (args[i - 1] === "--env" && /^[A-Za-z_]\w*=./.test(arg) ? [arg.slice(0, arg.indexOf("="))] : []));

/** The value of a flag in `args`, given as `--flag value`, `--flag=value` or, for a short flag, `-fvalue`; the last one wins. */
function valueOf(args, flags) {
  let value = null;
  args.forEach((arg, i) => {
    for (const flag of flags) {
      if (arg === flag) value = args[i + 1] ?? null;
      else if (arg.startsWith(flag.startsWith("--") ? `${flag}=` : flag)) value = arg.slice(flag.length).replace(/^=/, "");
    }
  });
  return value;
}

function cargoRun(rest) {
  const cargo = cargoSubcommand(pastRustupRun(rest));
  if (cargo?.name !== "run") return null;
  const args = ownArguments(cargo.args);
  const release = args.includes("--release") || args.includes("-r") || valueOf(args, ["--profile"]) === "release";
  const target = valueOf(args, ["--bin"]) ?? valueOf(args, ["-p", "--package"]);
  if (!release || !target || !NAMES_TARMAC.test(target)) return null;
  return isCli(target) ? SOCKET_ONLY : PINS;
}

// Flags of `swift run` that take a value in the next word.
const SWIFT_VALUED = new Set(["-c", "--configuration", "--package-path", "--scratch-path", "--build-path", "-j", "--jobs", "--triple", "--sdk", "--swift-sdk", "--arch", "-Xswiftc", "-Xcc", "-Xlinker", "-Xcxx"]);

function swiftRun(rest) {
  if (programOf(rest[0] ?? "") !== "swift" || rest[1] !== "run") return null;
  const args = ownArguments(rest.slice(2));
  if (valueOf(args, ["-c", "--configuration"])?.toLowerCase() !== "release") return null;
  let at = 0;
  while (at < args.length && args[at].startsWith("-")) at += SWIFT_VALUED.has(args[at]) ? 2 : 1;
  return NAMES_TARMAC.test(args[at] ?? "") ? PINS : null;
}

/** The pins a command's launch needs, or null when it launches nothing. The CLI reads only TARMAC_SOCKET and starts no daemon. */
function pinsFor(rest) {
  const program = rest[0] ?? "";
  if (built(program, [BUNDLE_EXECUTABLE, RELEASE_BINARY])) {
    if (programOf(program) === "tarmacd" && rest.length === 2 && rest[1] === "--version") return null;
    return programOf(program) === "tarmac" ? SOCKET_ONLY : PINS;
  }
  if (programOf(program) === "open") {
    const args = rest.slice(1).filter((arg) => !URL.test(arg) || /^file:/i.test(arg));
    return !args.includes("-R") && args.some((arg) => built(arg.replace(/^file:\/\//i, ""), [BUNDLE, BUNDLE_EXECUTABLE])) ? PINS : null;
  }
  return cargoRun(rest) ?? swiftRun(rest);
}

export const unpinnedLaunch = {
  watches: PINS,
  judge: (commands) =>
    commands.some(({ rest, env }) => {
      const needed = pinsFor(rest);
      if (!needed) return false;
      const given = new Set([...env, ...openEnv(rest)]);
      return !needed.every((name) => given.has(name));
    }),
  // Nested too deep to read: refused when it names such a path and not every pin.
  deep: (line) => /tarmac\.app|(target|\.build)\/([^/\s]+\/){0,2}release\//i.test(line) && !PINS.every((name) => new RegExp(`${name}=[^\\s;&|]`).test(line)),
};
