// The rule of the Bash hook: a Tarmac process is not killed by name. A dev
// build and the installed app share process names, so `pkill tarmacd` can end
// the installed app and every terminal it owns.
//
// It reads the command as a shell would, as far as text allows: quotes, the
// places a command starts, and programs that run their arguments. It does not
// expand a variable, read a script file, or follow an alias.

const KILLERS = new Set(["pkill", "killall"]);
// Programs that run the command in their arguments, after their own flags and values.
const WRAPPERS = new Set(["sudo", "doas", "env", "command", "exec", "time", "nohup", "nice", "timeout", "caffeinate", "xargs"]);
// Programs that run one argument as a whole command line.
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "eval"]);
const KEYWORDS = new Set(["if", "elif", "then", "else", "while", "until", "do", "!", "{", "("]);

/**
 * The simple commands of a command line, each a list of words with the quotes
 * removed. A command starts after `;`, `&`, `|`, a newline, `(`, `$(` and a
 * backtick; text in quotes starts none, except a `$(` or a backtick in double
 * quotes, which the shell runs.
 */
function simpleCommands(line) {
  const commands = [[]];
  let word = null;
  let quote = null;
  const endWord = () => {
    if (word !== null) commands.at(-1).push(word);
    word = null;
  };
  const endCommand = () => {
    endWord();
    commands.push([]);
    quote = null;
  };
  for (let at = 0; at < line.length; at++) {
    const char = line[at];
    if (quote === "'") {
      if (char === "'") quote = null;
      else word += char;
    } else if (char === "`" || (char === "$" && line[at + 1] === "(")) {
      endCommand();
      if (char === "$") at++;
    } else if (quote === '"') {
      if (char === '"') quote = null;
      else if (char === "\\" && at + 1 < line.length) word += line[++at];
      else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
      word ??= "";
    } else if (char === "\\" && at + 1 < line.length) {
      word = (word ?? "") + line[++at];
    } else if (";&|\n()".includes(char)) {
      endCommand();
    } else if (/\s/.test(char)) {
      endWord();
    } else {
      word = (word ?? "") + char;
    }
  }
  endWord();
  return commands.filter((words) => words.length > 0);
}

const programOf = (word) => word.split("/").pop();
// `t[a]rmac` and `tar\mac` match the same processes as `tarmac`.
const namesTarmac = (word) => /tarmac/i.test(word.replace(/[[\]\\^$]/g, ""));

function kills(words, line) {
  let rest = words;
  while (KEYWORDS.has(rest[0]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(rest[0] ?? "")) rest = rest.slice(1);
  if (rest.length === 0) return false;
  const program = programOf(rest[0]);
  if (SHELLS.has(program)) return rest.slice(1).some((word) => killsTarmacByName(word));
  const at = WRAPPERS.has(program) ? rest.findIndex((word, index) => index > 0 && KILLERS.has(programOf(word))) : 0;
  if (at < 0 || !KILLERS.has(programOf(rest[at]))) return false;
  // `… | xargs pkill` takes the names from its input, so the name may be anywhere in the line.
  return rest.slice(at + 1).some(namesTarmac) || (program === "xargs" && namesTarmac(line));
}

/** True for a command line that kills by name a process whose name holds "tarmac". */
export function killsTarmacByName(line) {
  return simpleCommands(line).some((words) => kills(words, line));
}
