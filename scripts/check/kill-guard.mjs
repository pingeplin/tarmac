// The rule of the Bash hook: a Tarmac process is not killed by name. A dev
// build and the installed app share process names, so `pkill tarmacd` can end
// the installed app and every terminal it owns.
//
// It reads the command as a shell would, as far as text allows: quotes, the
// places a command starts, and programs that run their arguments. It does not
// expand a variable, read a script file or a script on a shell's stdin, or
// follow an alias, and it knows no other way to end a process by name.

const KILLERS = new Set(["pkill", "killall"]);
// Programs that run the command in their arguments, after their own flags and values.
const WRAPPERS = new Set(["sudo", "doas", "env", "command", "exec", "time", "nohup", "nice", "timeout", "caffeinate", "xargs"]);
// Programs that run one argument as a whole command line.
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "eval"]);
const KEYWORDS = new Set(["if", "elif", "then", "else", "while", "until", "do", "!", "{"]);
// Programs that give the pids of processes found by name.
const FINDERS = new Set(["pgrep", "pidof"]);
// What the guard looks for after a wrapper, whatever stands between.
const RUN = new Set([...KILLERS, ...SHELLS, ...FINDERS, ...WRAPPERS, "kill"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/**
 * The simple commands of a command line, each with its words (quotes removed)
 * and, for one in a `$(…)` or a backtick pair, the command it is a word of. A command ends at `;`, `&`, `|` and a newline. A subshell, a
 * `$(…)` and a backtick pair hold commands of their own, also inside double
 * quotes, and the text after them goes on where it was. Text in quotes, a
 * comment and the body of a here-document start no command.
 */
function simpleCommands(line) {
  const commands = [];
  let at = 0;

  /** Reads commands up to `close` (")" or "`"), or to the end of the line. `within` is the command whose word they are part of. */
  function read(close, within = null) {
    let words = [];
    let word = null;
    const pending = [];
    const endWord = () => {
      if (word !== null) words.push(word);
      word = null;
    };
    const endCommand = () => {
      endWord();
      if (words.length > 0) commands.push({ words, within });
      words = [];
    };
    const nested = (closer) => {
      const outer = [words, word];
      words = [];
      word = null;
      read(closer, outer[0]);
      [words, word] = outer;
      word ??= "";
    };
    /** Text in double quotes: only a `$(` and a backtick run something. */
    const quoted = () => {
      word ??= "";
      for (; at < line.length && line[at] !== '"'; at++) {
        if (line[at] === "\\" && at + 1 < line.length) word += line[++at];
        else if (line[at] === "`" && close !== "`") (at++, nested("`"), at--);
        else if (line[at] === "$" && line[at + 1] === "(") ((at += 2), nested(")"), at--);
        else word += line[at];
      }
      at++;
    };
    /** `$'…'`: a backslash keeps the next character, a quote included. */
    const ansiQuoted = () => {
      word ??= "";
      for (at++; at < line.length && line[at] !== "'"; at++) word += line[at] === "\\" && at + 1 < line.length ? line[++at] : line[at];
      at++;
    };
    /** After `<<`: the delimiter. The body starts after the next newline. */
    const hereDocument = () => {
      const strip = line[at] === "-";
      if (strip) at++;
      while (line[at] === " " || line[at] === "\t") at++;
      let end = "";
      for (let quote = null; at < line.length && (quote || !/[\s;&|()<>]/.test(line[at])); at++) {
        if (line[at] === quote) quote = null;
        else if (!quote && (line[at] === "'" || line[at] === '"')) quote = line[at];
        else if (line[at] !== "\\" || quote) end += line[at];
      }
      pending.push({ end, strip });
    };
    const skipBodies = () => {
      for (const { end, strip } of pending.splice(0)) {
        while (at < line.length) {
          const stop = line.indexOf("\n", at);
          const text = line.slice(at, stop < 0 ? line.length : stop);
          at = stop < 0 ? line.length : stop + 1;
          if ((strip ? text.replace(/^\t+/, "") : text) === end) break;
        }
      }
    };

    while (at < line.length) {
      const char = line[at++];
      if (char === close) break;
      if (char === "'") {
        const end = line.indexOf("'", at);
        word = (word ?? "") + line.slice(at, end < 0 ? line.length : end);
        at = end < 0 ? line.length : end + 1;
      } else if (char === '"') quoted();
      else if (char === "\\" && at < line.length) word = (word ?? "") + line[at++];
      else if (char === "`") nested("`");
      else if (char === "$" && line[at] === "(") (at++, nested(")"));
      else if (char === "(") (endCommand(), read(")"));
      else if (char === "<" && line[at] === "<" && line[at + 1] === "<") at += 2;
      else if (char === "<" && line[at] === "<") (at++, hereDocument());
      else if (char === "$" && line[at] === "'") ansiQuoted();
      else if (char === "#" && word === null) while (at < line.length && line[at] !== "\n") at++;
      else if (char === "\n") (endCommand(), skipBodies());
      else if (";&|)".includes(char)) endCommand();
      else if (/\s/.test(char)) endWord();
      else word = (word ?? "") + char;
    }
    endCommand();
  }

  while (at < line.length) read(null);
  return commands;
}

const programOf = (word) => word.split("/").pop();
// `t[a]rmac` and `tar\mac` match the same processes as `tarmac`.
const namesTarmac = (word) => /tarmac/i.test(word.replace(/[[\]\\^$]/g, ""));

/**
 * The words of a command from its program on: keywords, assignments and
 * wrappers passed over. After a wrapper come its own flags, a value for a
 * flag, a number (`timeout 5`) and assignments (`env A=1`); the first word
 * that is none of these is the program.
 */
function fromProgram(words) {
  let rest = words;
  if (rest[0] === "function") rest = rest.slice(2);
  while (KEYWORDS.has(rest[0]) || ASSIGNMENT.test(rest[0] ?? "")) rest = rest.slice(1);
  let wrapper = null;
  while (WRAPPERS.has(programOf(rest[0] ?? ""))) {
    wrapper = programOf(rest[0]);
    // `command -v x` asks where x is; it runs nothing.
    if (wrapper === "command" && /^-[vV]$/.test(rest[1] ?? "")) return { rest: [], wrapper };
    let at = 1;
    for (let afterFlag = false; at < rest.length; at++) {
      const word = rest[at];
      if (RUN.has(programOf(word))) break;
      if (word.startsWith("-")) afterFlag = true;
      else if (afterFlag) afterFlag = false;
      else if (!/^\d/.test(word) && !ASSIGNMENT.test(word)) break;
    }
    rest = rest.slice(at);
  }
  return { rest, wrapper };
}

function reads(line) {
  const commands = simpleCommands(line).map(({ words, within }) => ({ words, within, ...fromProgram(words) }));
  const finders = commands.filter(({ rest }) => FINDERS.has(programOf(rest[0] ?? "")) && rest.slice(1).some(namesTarmac));
  let named = null;
  const anywhere = () => (named ??= namesTarmac(line));
  return commands.some(({ words, rest, wrapper }) => {
    const program = programOf(rest[0] ?? "");
    if (SHELLS.has(program)) return rest.slice(1).some(killsTarmacByName);
    // `kill $(pgrep tarmacd)` and `pgrep tarmacd | xargs kill` kill what a search by name found.
    if (program === "kill") return finders.some(({ within }) => within === words) || (wrapper === "xargs" && finders.length > 0);
    if (!KILLERS.has(program)) return false;
    // `… | xargs pkill` takes the names from its input, so the name may be anywhere in the line.
    return rest.slice(1).some(namesTarmac) || (wrapper === "xargs" && anywhere());
  });
}

/** True for a command line that kills by name a process whose name holds "tarmac". */
export function killsTarmacByName(line) {
  try {
    return reads(line);
  } catch {
    // Nested too deep to read (a stack overflow): refused when it holds the words of such a kill at all.
    return /pkill|killall|pgrep|pidof/.test(line) && namesTarmac(line);
  }
}
