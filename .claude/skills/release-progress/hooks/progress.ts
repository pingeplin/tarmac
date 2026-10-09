import type { Progress } from '../types'

export const STEPS = [
  'build',
  'sign',
  'notarize',
  'gatekeeper',
  'PR',
  'release',
  'tap',
  'verify',
] as const

// The `==>` lines of scripts/{bundle,dmg,release}.sh, in the order they run.
const MARKS: readonly (readonly [RegExp, number])[] = [
  [/^(freshness guard|building Rust core|building the native app|assembl)/, 0],
  [/^(signing|staging \.dmg|building .*\.dmg)/, 1],
  [/^(notarizing|done: |reusing the notarized)/, 2],
  [/^Gatekeeper/, 3],
  [/^(release PR|the version bump is already on main)/, 4],
  [/^GitHub release/, 5],
  [/^Homebrew tap/, 6],
  [/^verifying/, 7],
]

const DONE = /^(released v|v\S+ is already published)/
const FAILED = /^(FATAL: |make: \*\*\* )/
const VERSION = /Tarmac-(\d[^\s/]*)\.dmg|\(version ([^)]+)\)|^==> released v(\S+)/m

const RELEASE = /\bmake release\b|scripts\/release\.sh/
const TEE = /\|\s*tee\s+(?:-a\s+)?(?:"([^"]+)"|'([^']+)'|([^\s;|&)]+))/

const firstGroup = (match: RegExpExecArray | null) =>
  match?.slice(1).find(Boolean) ?? null

export function parseLog(text: string): Progress {
  const lines = text.split(/\r\n|\n|\r/).map(line => line.trim())
  const progress: Progress = {
    step: 0,
    status: 'running',
    line: lines.findLast(line => line !== '') ?? '',
    version: firstGroup(VERSION.exec(text)),
  }

  for (const line of lines) {
    if (FAILED.test(line)) {
      return { ...progress, status: 'failed', line }
    }

    if (!line.startsWith('==> ')) {
      continue
    }

    const said = line.slice(4)

    if (DONE.test(said)) {
      return { ...progress, status: 'done', line: said }
    }

    const mark = MARKS.find(([pattern]) => pattern.test(said))
    progress.step = mark?.[1] ?? progress.step
  }

  return progress
}

export function logOf(command: string): string | null {
  return RELEASE.test(command) ? firstGroup(TEE.exec(command)) : null
}

export function teeTargets(processes: string): string[] {
  return [...processes.matchAll(/^\d+ tee (?:-a )?(.+)$/gm)].flatMap(
    match => match[1] ?? [],
  )
}
