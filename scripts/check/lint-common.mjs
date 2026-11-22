// What the lints share: the rule's name in a report, the result of a clean
// run, and the result of a lint that could not run.

import { cannotRunFor } from "./report.mjs";

export const RULE = "lint";
export const CLEAN = { code: 0, text: "" };

/** A "could not run" result for a lint whose report ends with the given `then` command. */
export const blockedFor = (then) => {
  const report = cannotRunFor(RULE, then);
  return (...parts) => ({ code: 2, text: report(...parts) });
};

export const findings = (count, tool) => `${count} ${count === 1 ? "finding" : "findings"} from ${tool}`;
