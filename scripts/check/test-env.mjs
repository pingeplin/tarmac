// Imported first by every test file. git gives a hook the variables that name
// its repository (GIT_DIR in a linked worktree), and `make test` runs under the
// pre-push hook. A fixture's `git init`, `git commit` or `git config` with those
// variables set goes to the repository of the hook, not to the fixture (#502).
// So they leave the environment before a test starts a git of its own.
export const REPOSITORY_VARIABLES = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_IMPLICIT_WORK_TREE"];

for (const name of REPOSITORY_VARIABLES) delete process.env[name];
