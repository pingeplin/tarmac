// The DCO sign-off of a commit message: one reading for the commit-msg hook
// and for the check CI runs over a branch (scripts/dco-check.mjs), so the two
// cannot disagree about a message.

// One trailer per line. Anchored hard at column zero on purpose: `^\s*` would
// also match a trailer quoted inside an indented code block, so a commit that
// merely *documents* the sign-off format would pass as signed — which is exactly
// what a commit touching CONTRIBUTING.md looks like. `[^<\n]*` (not `.+`) keeps
// the capture on the FIRST bracket pair, so a second address cannot displace the
// real signer.
const SIGNOFF = /^Signed-off-by:[^<\n]*<([^>]+)>\s*$/gim;

const plain = (email) => email.trim().toLowerCase();

/** The email of each well-formed Signed-off-by line of a message, in lower case. */
export const signers = (body) => [...body.matchAll(SIGNOFF)].map((match) => plain(match[1]));

/** True when one of the signers is the author or the committer. */
export const signedBy = (signed, emails) => signed.some((email) => emails.filter(Boolean).map(plain).includes(email));
