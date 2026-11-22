import { execFileSync } from "node:child_process";

/** The root of the git repository that holds the current directory, or null outside one. */
export function repoRoot() {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}
