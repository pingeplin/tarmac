// A rule of the Bash hook: cargo-mutants does not run bare. mutants.mjs gives
// it an empty HOME and a short fixed list of variables, and that keeps a
// mutated path away from the real home. A run that only lists (`--list`,
// `--list-files`) or answers `--help` or `--version` runs no mutant.
//
// It reads `cargo mutants`, `cargo-mutants`, `cargo +toolchain mutants` with
// cargo's own flags before the subcommand, and `rustup run <toolchain>` before
// either, as shell-commands.mjs reads a line. It does not see cargo-mutants
// under another name (a link, an alias, a cargo alias in a config file), or
// started by a program that is not in the reader's table.

import { cargoSubcommand, ownArguments, pastRustupRun, programOf } from "./shell-commands.mjs";

const RUNS_NOTHING = new Set(["--list", "--list-files", "--help", "-h", "--version", "-V"]);

/** The arguments cargo-mutants gets from a command, or null when the command does not run it. */
function mutantsArguments(words) {
  const rest = pastRustupRun(words);
  if (programOf(rest[0] ?? "") === "cargo-mutants") return rest.slice(1);
  const cargo = cargoSubcommand(rest);
  return cargo?.name === "mutants" ? cargo.args : null;
}

export const bareMutants = {
  judge: (commands) =>
    commands.some(({ rest }) => {
      const args = mutantsArguments(rest);
      // A `--list` after `--` goes to the tests, and the mutants run.
      return args !== null && !ownArguments(args).some((arg) => RUNS_NOTHING.has(arg));
    }),
  // Nested too deep to read: refused when it holds the words of such a run and no `--list`.
  deep: (line) => /cargo[\s-]+mutants/i.test(line) && !/--list/.test(line),
};
