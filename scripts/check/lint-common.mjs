// What the lints share: the rule's name in a report, the result of a clean
// run, and the wording of a count of findings.

export const RULE = "lint";
export const CLEAN = { code: 0, text: "" };

export const findings = (count, tool) => `${count} ${count === 1 ? "finding" : "findings"} from ${tool}`;
