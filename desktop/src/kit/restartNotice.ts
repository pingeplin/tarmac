// Spec 2609.0017 (#172): whether a first-visit restore after a version-mismatch
// restart gets a toast. Loss is proven by a persisted term id that came back not
// live, never by a bare coldSpawn — every fresh ⌘N board yields one of those with
// nothing lost. The latch (daemonRestartToastedRef) and pushToast stay in App.tsx.

export interface RestartNotice {
  title: string;
  body: string;
}

/**
 * Non-null iff `replaced` is present, `alreadyNotified` is false, and at least one
 * tile carries a persisted id absent from `liveTerms`. A null version reads as
 * "unknown"; the arrow claims no direction, because the restart fired on `!=`.
 */
export function restartNotice(
  replaced: { from: string | null; to: string | null } | undefined,
  tileTermIds: (string | null)[],
  liveTerms: Set<string>,
  alreadyNotified: boolean,
): RestartNotice | null {
  if (!replaced || alreadyNotified) return null;
  const lost = tileTermIds.filter((id) => id !== null && !liveTerms.has(id)).length;
  if (lost === 0) return null;
  return {
    title: `tarmacd restarted: ${replaced.from ?? "unknown"} → ${replaced.to ?? "unknown"}`,
    body:
      lost === 1
        ? "1 terminal on this board was restarted"
        : `${lost} terminals on this board were restarted`,
  };
}
