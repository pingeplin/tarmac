// The one place that words a failed check, and the format for every new check:
// the rule, the places, the reason, and the next two commands, always in the
// same position. (docs-check and dco-check predate it and keep their own.)

import { startedAs } from "./git.mjs";

/**
 * `at` and `why` are lists of lines and may be empty. `fix` and `then` are
 * commands, and a failure without them cannot be written: a check that only
 * says "failed" leaves the reader with nothing to do.
 */
export function failure({ rule, summary, at = [], why = [], fix, then }) {
  for (const [name, command] of Object.entries({ fix, then })) {
    if (!command) throw new Error(`a ${rule} failure needs a ${name} command`);
  }
  const lines = [
    `✗ ${rule}: ${summary}`,
    ...rows("at", [...at].sort(byBytes)),
    ...rows("why", why),
    row("fix", fix),
    row("then", then),
    "",
  ];
  return lines.join("\n");
}

/** The "could not run" result of one check: its rule and its `then` command are fixed, the rest varies. */
export const blockedFor = (rule, then) => (summary, why, fix) => ({ code: 2, text: failure({ rule, summary, why, fix, then }) });

/**
 * The result `{ code, text, out? }` of a check's `main`, sync or async. An
 * exception has not judged anything, and neither has a `main` that gives no
 * result: both are "could not run" (2). Left alone, node would end with 1,
 * which a caller reads as a finding, or with 0.
 */
async function resultOf({ rule, then }, main) {
  try {
    const result = await main();
    if (![0, 1, 2].includes(result?.code) || typeof result.text !== "string") throw new Error("the check gave no result");
    return result;
  } catch (error) {
    return blockedFor(rule, then)("the check itself failed", raised(error), then);
  }
}

/** What was thrown, and the place in the code if it has one. */
const raised = (error) => [String(error?.message ?? error), ...(error?.stack?.match(/^ +at .+$/m) ?? []).map((frame) => frame.trim())];

/** The entry of every check script with the 0/1/2 contract; it does nothing in a module that is only imported. */
export async function runCheck(meta, check, main) {
  if (!startedAs(meta)) return;
  const { code, text, out = "" } = await resultOf(check, main);
  process.stdout.write(out);
  process.stderr.write(text);
  process.exitCode = code;
}

const row = (label, text) => `  ${label.padEnd(4)} ${text}`;

const rows = (label, texts) => texts.map((text, i) => row(i === 0 ? label : "", text));

const byBytes = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
