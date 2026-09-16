// `tarmac dev snapshot --until <expr>` (spec 2609.0015, issue #166): a tiny,
// hand-written predicate over a snapshot. Hand-written rather than `eval`-backed
// because the driver executes UI actions on request and must never execute a
// caller's code — and because the grammar is deliberately smaller than anything
// a general expression engine would give.
//
//   <path> <op> <value>
//   op    == | != | ~= (numeric, |Δ| ≤ 1) | contains
//   path  dotted; `cards[<id>]` indexes by card id, where the id runs to the LAST
//         `]` in the remainder — doc paths contain dots, slashes, and may contain
//         a `]`, and none of them may be treated as syntax.
//   value number | "string" (\" and \\) | null | true | false
//
// Two failure modes that must stay distinguishable:
//   - an UNRESOLVABLE path evaluates to false, in both polarities, so a card that
//     has not rendered yet keeps the poll going rather than failing the run;
//   - a MALFORMED expression is a parse error, so the app answers `bad_expr` at
//     once instead of spending the whole timeout on something that can never hold.

export type UntilOp = "==" | "!=" | "~=" | "contains";
export type UntilValue = string | number | boolean | null;

export interface UntilExpr {
  path: string;
  op: UntilOp;
  value: UntilValue;
}

export interface UntilParseError {
  error: string;
}

/** How close `~=` counts as equal, in the value's own units. */
export const NUMERIC_TOLERANCE = 1;

const MISSING = Symbol("missing");

export function parseUntil(src: string): UntilExpr | UntilParseError {
  const text = src.trim();
  if (text === "") return { error: "empty expression" };

  // `contains` is a word, the rest are symbols; match the word first so a path
  // ending in "contains" cannot be mistaken for the operator.
  const match =
    /^(.*?)\s+(contains)\s+(.*)$/.exec(text) ?? /^(.*?)\s*(==|!=|~=)\s*(.*)$/.exec(text);
  if (!match) return { error: `expected <path> <op> <value>, got ${JSON.stringify(src)}` };

  const [, rawPath, op, rawValue] = match;
  const path = rawPath.trim();
  if (path === "") return { error: "missing path" };
  const value = parseValue(rawValue.trim());
  if (value === MISSING) return { error: `not a value: ${JSON.stringify(rawValue.trim())}` };
  return { path, op: op as UntilOp, value };
}

function parseValue(src: string): UntilValue | typeof MISSING {
  if (src === "null") return null;
  if (src === "true") return true;
  if (src === "false") return false;
  if (src.startsWith('"')) {
    let out = "";
    for (let i = 1; i < src.length; i++) {
      const ch = src[i];
      if (ch === "\\") {
        const next = src[++i];
        if (next === undefined) return MISSING;
        out += next;
      } else if (ch === '"') {
        return i === src.length - 1 ? out : MISSING; // trailing junk
      } else {
        out += ch;
      }
    }
    return MISSING; // unterminated
  }
  if (src === "" ) return MISSING;
  const n = Number(src);
  return Number.isFinite(n) ? n : MISSING;
}

/** Walk the path. Returns MISSING — never throws, never undefined — for anything
 *  that does not resolve, so the caller can treat "not there" as one state. */
function resolve(root: unknown, path: string): unknown | typeof MISSING {
  let node: unknown = root;
  let rest = path;
  while (rest.length > 0) {
    if (node === null || typeof node !== "object") return MISSING;
    if (rest.startsWith("cards[")) {
      // Everything up to the LAST `]` is the literal id.
      const close = rest.lastIndexOf("]");
      if (close < 0) return MISSING;
      const id = rest.slice("cards[".length, close);
      const cards = (node as Record<string, unknown>).cards;
      if (!Array.isArray(cards)) return MISSING;
      const card = cards.find((c) => (c as Record<string, unknown>)?.id === id);
      if (card === undefined) return MISSING;
      node = card;
      rest = rest.slice(close + 1).replace(/^\./, "");
      continue;
    }
    const dot = rest.indexOf(".");
    const key = dot < 0 ? rest : rest.slice(0, dot);
    rest = dot < 0 ? "" : rest.slice(dot + 1);
    if (!(key in (node as Record<string, unknown>))) return MISSING;
    node = (node as Record<string, unknown>)[key];
  }
  return node;
}

export function evalUntil(expr: UntilExpr, snapshot: unknown): boolean {
  const actual = resolve(snapshot, expr.path);
  // An unresolvable path makes no claim, so NEITHER polarity may fire — `!=`
  // included, or a typo'd path would satisfy every `!=` immediately.
  if (actual === MISSING) return false;
  switch (expr.op) {
    case "==":
      return actual === expr.value;
    case "!=":
      return actual !== expr.value;
    case "~=":
      return (
        typeof actual === "number" &&
        typeof expr.value === "number" &&
        Math.abs(actual - expr.value) <= NUMERIC_TOLERANCE
      );
    case "contains":
      return typeof actual === "string" && typeof expr.value === "string" && actual.includes(expr.value);
  }
}
