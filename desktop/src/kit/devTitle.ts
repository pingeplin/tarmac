// Window-title suffix identifying a `make run` dev app by its worktree; empty
// for a shipped app. Why it exists: the `run` recipe in the Makefile.

export function devTitleSuffix(label: string | undefined): string {
  const trimmed = label?.trim() ?? "";
  return trimmed ? ` · ${trimmed}` : "";
}
