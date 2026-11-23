// The rules of the Bash hook, in the order they are asked, each with the words
// of its refusal. A line is read once; the first rule that refuses it answers.

import { bareMutants } from "./mutants-guard.mjs";
import { killByName } from "./kill-guard.mjs";
import { unpinnedLaunch } from "./launch-guard.mjs";
import { failure } from "./report.mjs";
import { firstRefusing } from "./shell-commands.mjs";

const GUARDS = [
  {
    ...killByName,
    summary: "a Tarmac process is not killed by name",
    why: ["a dev build and the installed app share process names; a kill by name can end the installed app and every terminal it owns"],
    fix: "make kill-daemon   (it finds this worktree's daemon by its socket), or kill one pid you have checked",
    then: "run the command again without pkill or killall",
  },
  {
    ...bareMutants,
    summary: "cargo mutants does not run bare",
    why: ["scripts/check/mutants.mjs gives cargo-mutants an empty HOME and a short fixed list of variables; that keeps a mutated path away from the real home"],
    fix: "make mutants   (FILE=<path> for every mutant of one file, ALL=1 for the whole workspace)",
    then: "run make mutants in place of the command; cargo mutants --list runs nothing and is not refused",
  },
  {
    ...unpinnedLaunch,
    summary: "a built app or a release binary does not launch with its channel unpinned",
    why: ["a release build resolves the installed channel: it attaches to the user's daemon and, on a version mismatch, SIGTERMs and replaces it, with every terminal that daemon owns"],
    fix: "make run   (it pins the channel for you), or set TARMAC_SOCKET, TARMAC_STATE and TARMAC_CONFIG_DIR to paths of your own in the same command",
    then: "TARMAC_SOCKET=$PWD/.dev/rel/tarmacd.sock TARMAC_STATE=$PWD/.dev/rel/state.json TARMAC_CONFIG_DIR=$PWD/.dev/rel/config <the command>",
  },
];

/** The refusal of a command line in the reporter's form, or null when every rule lets it run. */
export function refusalOf(line) {
  const refused = firstRefusing(GUARDS, line);
  if (!refused) return null;
  const { summary, why, fix, then } = refused;
  return failure({ rule: "bash", summary, why, fix, then });
}
