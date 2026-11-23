// The rule of the Bash hook: a Tarmac process is not killed by name. A dev
// build and the installed app share process names, so `pkill tarmacd` can end
// the installed app and every terminal it owns.
//
// It reads the command as shell-commands.mjs does. It knows no other way to end
// a process by name.

import { programOf, refuses } from "./shell-commands.mjs";

const KILLERS = new Set(["pkill", "killall"]);
// Programs that give the pids of processes found by name.
const FINDERS = new Set(["pgrep", "pidof"]);

// `t[a]rmac` and `tar\mac` match the same processes as `tarmac`.
const namesTarmac = (word) => /tarmac/i.test(word.replace(/[[\]\\^$]/g, ""));

/** The judge of one line's commands. */
function killsIn({ line, commands }) {
  const finders = commands.filter(({ rest }) => FINDERS.has(programOf(rest[0] ?? "")) && rest.slice(1).some(namesTarmac));
  const searched = new Set(finders.map(({ within }) => within));
  let named = null;
  const anywhere = () => (named ??= namesTarmac(line));
  return ({ words, rest, wrapper }) => {
    const program = programOf(rest[0] ?? "");
    // `kill $(pgrep tarmacd)` and `pgrep tarmacd | xargs kill` kill what a search by name found; `kill -0` only asks.
    if (program === "kill") return !rest.includes("-0") && (searched.has(words) || (wrapper === "xargs" && finders.length > 0));
    if (!KILLERS.has(program)) return false;
    // `… | xargs pkill` takes the names from its input, so the name may be anywhere in the line.
    return rest.slice(1).some(namesTarmac) || (wrapper === "xargs" && anywhere());
  };
}

export const killByName = {
  judge(commands) {
    const judges = new Map();
    return commands.some((command) => {
      if (!judges.has(command.level)) judges.set(command.level, killsIn(command.level));
      return judges.get(command.level)(command);
    });
  },
  // Nested too deep to read: refused when it holds the words of such a kill at all.
  deep: (line) => /pkill|killall|pgrep|pidof/i.test(line) && namesTarmac(line),
};

/** True for a command line that kills by name a process whose name holds "tarmac". */
export const killsTarmacByName = (line) => refuses(killByName, line);
