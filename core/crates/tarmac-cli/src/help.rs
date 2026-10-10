//! The `--help` text. The `dev` family is a debug-build affordance, so a release
//! binary does not advertise it, as `README.md` and `GUIDE.md` do not. A release
//! `tarmac dev` still exits 1 with "driver unavailable": the verb is recognised,
//! just not advertised to someone who can never run it.

use crate::skill;

#[cfg(debug_assertions)]
const DEV_SOCKET: &str = " The dev driver's socket sits beside it as\ntarmac-dev.sock; override with TARMAC_DEV_SOCKET.";
#[cfg(not(debug_assertions))]
const DEV_SOCKET: &str = "";

#[cfg(debug_assertions)]
const DEV_USAGE: &str = "    tarmac dev <verb>       drive and inspect the running app (dev builds only)\n";
#[cfg(not(debug_assertions))]
const DEV_USAGE: &str = "";

#[cfg(debug_assertions)]
const DEV_HELP: &str = "`tarmac dev` talks to the app, not the daemon, over its own socket
(TARMAC_DEV_SOCKET). It exists so an agent or a script can drive and read the
cockpit without a keyboard, and it is available in dev builds only — a release
binary exits 1 with \"driver unavailable in release builds\".

    tarmac dev snapshot [--until <expr>] [--timeout <ms>]
    tarmac dev zoom <z>
    tarmac dev resize <card> <w>x<h>
    tarmac dev focus <card>|board
    tarmac dev type <card> \"<text>\"
    tarmac dev key <card> \"<combo>\"
    tarmac dev press <combo> [--hold <ms>] [--age <ms>] [--busy <ms>]

<card> is a terminal's term id or a doc's absolute path. snapshot prints JSON on
stdout; every other verb prints a small JSON object describing what it observed.
A failing verb prints the app's JSON error on stderr and exits 1.

`dev press` is the one verb that reaches AppKit: it posts a native ⌘ chord
(cmd plus shift/alt/ctrl, then one lowercase letter or digit) to the cockpit
window, activating the app if it is not key, and the snapshot's quit_guard
reports what the ⌘Q guard did with it. A chord that would reach a native
terminate: item is refused. It steals focus, so keep your hands off other apps;
a ⌘Q --hold of 500 or more, two ⌘Q within 1 s, or --age past 2000 ms really
quit the app.

Three things `dev key` cannot do, by design rather than by omission:
  - ⌘C and ⌘V cannot be driven through `key`. They rely on WebKit's native
    Edit-menu action, which an untrusted dispatched event never triggers;
    `press` posts them, but nothing in the snapshot shows what they did.
  - A bare printable character is refused; use `tarmac dev type` for text.
    xterm stands aside for such a key, so dispatching one would send nothing.
  - `focus` and `key` go through the real mouse and key paths, so a program with
    mouse reporting on (Claude Code, vim) also receives a button-press report
    when a card is focused.

One combo leaves the cockpit somewhere else, which is worth knowing before a
scenario blames the next verb:
  - `contextmenu` right-clicks the last written cell to make a selection. xterm
    moves its helper textarea to 20x20 px under the cursor and refocuses it, and
    leaves it there; that is what makes the selection real, and a following
    `type` still lands.

`dev type` sends printable characters through the editing path — the one a real
keystroke takes — and control characters as key events: LF and CR are Enter, TAB
is Tab, ESC and DEL are Escape and Backspace, and 0x01-0x1a are the ctrl chords
they stand for, so 0x03 is ctrl+c. (0x00 and 0x1c-0x1f have no spelling in the
combo grammar and take the editing path like any other character.) Under a program that asked for every key as an escape code (kitty flag
8) the editing path would deliver each character twice, so `type` sends key
events for those too and its reply reports mode: key.

One trap comes with that mode: while flag 8 is set, `dev key <card> ctrl+c`
cannot interrupt a program that does not speak the kitty protocol. xterm encodes
it as an escape code instead of a raw 0x03, so the line discipline never raises
SIGINT; ctrl+d behaves the same. The flags also survive an app reload, because
the replayed scrollback re-applies them. If a program leaves them set, nothing
can be sent as raw bytes and the pop sequence has to come from the program side
— write it to that terminal's own tty, e.g.
`printf '\\033[>0u' > /dev/ttysNNN`.

";
#[cfg(not(debug_assertions))]
const DEV_HELP: &str = "";

const HELP_HEAD_FMT: &str = "\
tarmac — agent cockpit CLI

USAGE:
    tarmac open <path>      register a file with the running tarmac app
    tarmac --version        report the cli, daemon, and app versions
    tarmac skill            print the agent-facing Tarmac guide
    tarmac skill install    install a SKILL.md that points coding agents at it
{DEV_USAGE}    tarmac --help           show this help

`tarmac open` is fire-and-forget: anything (you, an agent, a Makefile, a git
hook) can run it to surface a doc in the cockpit. The path is canonicalized
and must point to an existing file.

{DEV_HELP}`tarmac skill` never talks to the daemon. `install` writes one SKILL.md per
target — claude-code (~/.claude/skills) and codex (~/.agents/skills) — and
accepts:
";

const HELP_TAIL_FMT: &str = "
The daemon socket defaults to ~/Library/Application Support/tarmac/tarmacd.sock
(release builds) or ~/Library/Application Support/tarmac/dev/tarmacd.sock (dev
builds); override with TARMAC_SOCKET.{DEV_SOCKET}

`tarmac --version` reports three versions that drift independently — this cli
binary, the running daemon, and the app connected to that daemon — plus the
channel and socket it resolved, so a shadowing dev build is self-evident. It
exits 0 whether or not a daemon is running.

EXIT STATUS:
    0  success; also `tarmac --version` with no daemon running
    1  the daemon rejected the open, no daemon is running, or an install failed
    2  usage error
";

pub fn text() -> String {
    let head = HELP_HEAD_FMT.replace("{DEV_USAGE}", DEV_USAGE).replace("{DEV_HELP}", DEV_HELP);
    let tail = HELP_TAIL_FMT.replace("{DEV_SOCKET}", DEV_SOCKET);
    format!("{head}{}{tail}", skill::USAGE)
}
