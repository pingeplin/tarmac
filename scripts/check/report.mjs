// The one place that words a failed check, and the format for every new check:
// the rule, the places, the reason, and the next two commands, always in the
// same position. (docs-check and dco-check predate it and keep their own.)

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

const row = (label, text) => `  ${label.padEnd(4)} ${text}`;

const rows = (label, texts) => texts.map((text, i) => row(i === 0 ? label : "", text));

const byBytes = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
