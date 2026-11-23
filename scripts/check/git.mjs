import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";

/**
 * The root of the git repository that holds a directory (the current one by default), or null outside one.
 *
 * git gives a hook `GIT_DIR` in a linked worktree, and with it `--show-toplevel`
 * answers with the directory it was asked from. The question here is about the
 * directory, so it is asked without the variables that name a repository (#502).
 */
export function repoRoot(directory = process.cwd()) {
  const { GIT_DIR, GIT_WORK_TREE, ...env } = process.env;
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: directory, env, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
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
