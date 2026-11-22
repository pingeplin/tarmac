import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";

/** The root of the git repository that holds a directory (the current one by default), or null outside one. */
export function repoRoot(directory = process.cwd()) {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

/** True in the module that node was started on, also when it was named through a symlink. */
export function startedAs(meta) {
  try {
    return meta.filename === realpathSync(process.argv[1]);
  } catch {
    // `node -e` and the REPL start no file.
    return false;
  }
}
