// The one place that words a failed check. Every check prints the same four
// parts, so a person or an agent always finds the rule, the place, the reason
// and the next command in the same position.

const LABELS = ["at", "why"];

/**
 * `at` and `why` are lists of lines and may be empty. `fix` and `then` are
 * commands, and a failure without them cannot be written: a check that only
 * says "failed" leaves the reader with nothing to do.
 */
export function failure({ rule, summary, at = [], why = [], fix, then }) {
  if (!fix) throw new Error(`a ${rule} failure needs a fix command`);
  if (!then) throw new Error(`a ${rule} failure needs a then command`);
  const parts = { at: [...at].sort(byBytes), why };
  const lines = [`✗ ${rule}: ${summary}`];
  for (const label of LABELS) parts[label].forEach((text, i) => lines.push(row(i === 0 ? label : "", text)));
  lines.push(row("fix", fix), row("then", then), "");
  return lines.join("\n");
}

const row = (label, text) => `  ${label.padEnd(4)} ${text}`;

const byBytes = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
