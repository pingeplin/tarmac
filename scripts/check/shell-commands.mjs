// How the rules of the Bash hook read a command line: as a shell would, as far
// as text allows. Quotes, the places a command starts, and programs that run
// their arguments are read. A variable is not expanded, a script file or a
// script on a shell's stdin is not read, and an alias is not followed.

// Programs that run the command in their arguments, each with its flags that
// take a value in the next word. Any other flag stands alone, and a value may
// be joined to its flag (`-n5`, `--signal=KILL`). `first` is a positional
// argument before the command (the duration of `timeout`).
const WRAPPERS = new Map(
  Object.entries({
    sudo: { valued: ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t", "--user", "--group", "--host", "--prompt", "--chdir"] },
    doas: { valued: ["-u", "-C"] },
    env: { valued: ["-u", "-C", "-P", "--unset", "--chdir"] },
    nice: { valued: ["-n", "--adjustment"] },
    timeout: { valued: ["-s", "-k", "--signal", "--kill-after"], first: true },
    caffeinate: { valued: ["-t", "-w"] },
    xargs: { valued: ["-n", "-I", "-L", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S", "--max-args", "--max-procs", "--replace", "--delimiter"] },
    time: { valued: ["-o", "-f"] },
    exec: { valued: ["-a"] },
    command: {},
    builtin: {},
    nohup: {},
    noglob: {},
    coproc: {},
  }).map(([name, { valued = [], ...rest }]) => [name, { valued: new Set(valued), ...rest }]),
);
// Programs that run one argument as a whole command line.
const SHELLS = new Set(["sh", "bash", "zsh", "dash"]);
const KEYWORDS = new Set(["if", "elif", "then", "else", "while", "until", "do", "!", "{"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
// `2>/dev/null`, `>out` and `&>out` may stand before the program; `2>` has its target in the next word.
const REDIRECTION = /^(\d*|&)[<>]/;
const BARE_REDIRECTION = /^(\d*|&)[<>]+&?$/;
// How deep `eval` and `sh -c` are followed before the text alone decides.
const DEPTH = 20;

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
        if (line[at] === "\\" && line[at + 1] === "\n") at++;
        else if (line[at] === "\\" && at + 1 < line.length) word += line[++at];
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
      else if (char === "\\" && line[at] === "\n") at++;
      else if (char === "\\" && at < line.length) word = (word ?? "") + line[at++];
      else if (char === "`") nested("`");
      else if (char === "$" && line[at] === "(") (at++, nested(")"));
      else if (char === "(") (endCommand(), read(")"));
      else if (char === "<" && line[at] === "<" && line[at + 1] === "<") at += 2;
      else if (char === "<" && line[at] === "<") (at++, hereDocument());
      else if (char === "$" && line[at] === "'") ansiQuoted();
      else if (char === "#" && word === null) while (at < line.length && line[at] !== "\n") at++;
      else if (char === "\n") (endCommand(), skipBodies());
      else if (char === "&" && (line[at - 2] === ">" || line[at] === ">")) word = (word ?? "") + char;
      else if (";&|)".includes(char)) endCommand();
      else if (/\s/.test(char)) endWord();
      else word = (word ?? "") + char;
    }
    endCommand();
  }

  while (at < line.length) read(null);
  return commands;
}

// The macOS file system ignores letter case, so `PKILL` is `pkill`.
export const programOf = (word) => word.split("/").pop().toLowerCase();

/**
 * The words of a command from its program on: keywords, assignments,
 * redirections and wrappers passed over. After a wrapper come its flags, the
 * value of a flag that takes one, assignments, and for some one argument.
 * `assigned` holds the assignments passed over.
 */
function fromProgram(words) {
  let at = words[0] === "function" ? 2 : 0;
  const assigned = [];
  const passLeads = () => {
    for (; at < words.length; at++) {
      if (BARE_REDIRECTION.test(words[at])) at++;
      else if (ASSIGNMENT.test(words[at])) assigned.push(words[at]);
      else if (!(KEYWORDS.has(words[at]) || REDIRECTION.test(words[at]))) break;
    }
  };
  passLeads();
  let wrapper = null;
  while (at < words.length && WRAPPERS.has(programOf(words[at]))) {
    wrapper = programOf(words[at++]);
    const { valued, first = false } = WRAPPERS.get(wrapper);
    const flagsFrom = at;
    while (at < words.length && words[at].startsWith("-") && words[at] !== "--") at += valued.has(words[at]) ? 2 : 1;
    // `command -v x` asks where x is; it runs nothing.
    if (wrapper === "command" && words.slice(flagsFrom, at).some((flag) => /^-[pvV]*[vV][pvV]*$/.test(flag))) return { rest: [], wrapper, assigned };
    if (words[at] === "--") at++;
    passLeads();
    if (first) (at++, passLeads());
  }
  return { rest: words.slice(at), wrapper, assigned };
}

/** `names` with each watched `NAME=value` set, or dropped when its value is empty; the same set when no watched name changes. */
function withAssignments(names, assignments, watched) {
  let next = names;
  for (const assignment of assignments) {
    const name = assignment.slice(0, assignment.indexOf("="));
    if (!watched.has(name)) continue;
    // Only watched names are copied, so a line of many exports stays linear.
    if (next === names) next = new Set(names);
    if (assignment.length > name.length + 1) next.add(name);
    else next.delete(name);
  }
  return next;
}

const NOTHING = new Set();

/**
 * Every simple command of a line, also those that `eval` and a shell's
 * argument run, in the order they stand. Each has its `words`, the program on
 * (`rest`), the last `wrapper`, the command it is a word of (`within`), its
 * `level` (`{ line, commands }`: the line it was read from, with that line's
 * commands), and `env`: the `watched` names it is given a non-empty value
 * for, by its own assignments, by an `export` before it, or by the command
 * that runs it. Throws a RangeError for text nested too deep to read.
 */
function commandsOf(line, watched) {
  const all = [];
  const walk = (text, given, depth) => {
    if (depth > DEPTH) throw new RangeError("too deep");
    const level = { line: text, commands: [] };
    level.commands = simpleCommands(text).map(({ words, within }) => ({ words, within, ...fromProgram(words), level }));
    let exported = given;
    for (const command of level.commands) {
      command.env = withAssignments(exported, command.assigned, watched);
      all.push(command);
      const program = programOf(command.rest[0] ?? "");
      // `eval` joins its arguments into one command line; a shell takes one argument as the line.
      if (program === "eval") walk(command.rest.slice(1).join(" "), command.env, depth + 1);
      else if (SHELLS.has(program)) command.rest.slice(1).forEach((word) => walk(word, command.env, depth + 1));
      else if (program === "export") exported = withAssignments(exported, command.rest.slice(1).filter((word) => ASSIGNMENT.test(word)), watched);
    }
  };
  walk(line, NOTHING, 0);
  return all;
}

/**
 * The first of the rules (`{ judge(commands), deep(line), watches? }`) that
 * refuses a line, or undefined. The line is read once; text too deep to read
 * is judged by each rule's words.
 */
export function firstRefusing(rules, line) {
  let commands = null;
  try {
    commands = commandsOf(line, new Set(rules.flatMap(({ watches = [] }) => watches)));
  } catch {
    // Too deep to read.
  }
  return rules.find((rule) => (commands ? rule.judge(commands) : rule.deep(line)));
}

/** Whether a rule refuses a line. */
export const refuses = (rule, line) => firstRefusing([rule], line) !== undefined;

/** The words after `rustup run [flags] <toolchain>`, or the words themselves. */
export function pastRustupRun(rest) {
  if (programOf(rest[0] ?? "") !== "rustup" || rest[1] !== "run") return rest;
  let at = 2;
  while (rest[at]?.startsWith("-")) at++;
  return rest.slice(at + 1);
}

// Flags of cargo itself that take a value in the next word.
const CARGO_VALUED = new Set(["--color", "--config", "-C", "-Z"]);

/** For a cargo command, its subcommand (lower case) and the arguments after it; null for any other program. */
export function cargoSubcommand(rest) {
  if (programOf(rest[0] ?? "") !== "cargo") return null;
  let at = 1;
  while (rest[at]?.startsWith("+") || (rest[at]?.startsWith("-") && rest[at] !== "--")) at += CARGO_VALUED.has(rest[at]) ? 2 : 1;
  return { name: rest[at]?.toLowerCase(), args: rest.slice(at + 1) };
}

/** The words before a `--` that hands the rest to the program that is run. */
export const ownArguments = (args) => (args.includes("--") ? args.slice(0, args.indexOf("--")) : args);
