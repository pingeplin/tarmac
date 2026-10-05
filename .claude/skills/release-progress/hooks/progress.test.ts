import { expect, test } from 'claude-code/testing'

import { logOf, parseLog, STEPS, teeTargets } from './progress'

const BUILT = [
  '==> freshness guard: HEAD must contain origin/main',
  '==> building Rust core (release, arm64)',
  '   Compiling tarmacd v0.15.1',
  '==> building the native app (release)',
  '==> assembling dist/Tarmac.app (version 0.15.1)',
  '==> assembled dist/Tarmac.app',
]
const NOTARIZED = [
  ...BUILT,
  '==> signing (identity: Developer ID Application: X)',
  '==> staging .dmg layout',
  '==> building dist/Tarmac-0.15.1.dmg',
  '==> notarizing (this can take a few minutes)',
  '  status: In Progress',
]

test('an empty log is a running release at its first step', async () => {
  expect(parseLog('')).toEqual({
    step: 0,
    status: 'running',
    line: '',
    version: null,
  })
})

test('the last marker names the step, the last line the detail', async () => {
  expect(parseLog(NOTARIZED.join('\n'))).toEqual({
    step: 2,
    status: 'running',
    line: 'status: In Progress',
    version: '0.15.1',
  })
})

test('building the dmg is signing, not the build step', async () => {
  expect(parseLog(NOTARIZED.slice(0, 9).join('\n')).step).toBe(1)
})

test('each release.sh marker advances one step', async () => {
  const tail = [
    '==> Gatekeeper assessment',
    '==> release PR',
    '==> GitHub release v0.15.1',
    '==> Homebrew tap',
    '==> verifying what was published',
  ]

  tail.forEach((_, at) => {
    const text = [...NOTARIZED, ...tail.slice(0, at + 1)].join('\n')
    expect(parseLog(text).step).toBe(STEPS.indexOf('gatekeeper') + at)
  })
})

test('a reused dmg skips to past notarization', async () => {
  const text = '==> reusing the notarized dist/Tarmac-0.15.1.dmg\n'
  expect(parseLog(text)).toMatchObject({ step: 2, version: '0.15.1' })
})

test('released ends the run', async () => {
  const text = [...NOTARIZED, '==> released v0.15.1', ''].join('\n')
  expect(parseLog(text)).toMatchObject({
    status: 'done',
    line: 'released v0.15.1',
  })
})

test('a FATAL line fails the run at the step it reached', async () => {
  const text = [
    ...NOTARIZED,
    '==> release PR',
    'FATAL: PR #200 did not merge',
    'make: *** [release] Error 1',
  ].join('\n')

  expect(parseLog(text)).toMatchObject({
    step: 4,
    status: 'failed',
    line: 'FATAL: PR #200 did not merge',
  })
})

test('a release command names its tee target', async () => {
  expect(logOf('VERSION=1.0.0 make release 2>&1 | tee "/tmp/a b/r.log"')).toBe(
    '/tmp/a b/r.log',
  )
  expect(logOf('scripts/release.sh | tee -a out.log')).toBe('out.log')
  expect(logOf('make test | tee out.log')).toBe(null)
  expect(logOf('make release')).toBe(null)
})

test('the logs being teed are read from the processes, their shell skipped', async () => {
  const processes = [
    "69574 /bin/zsh -c eval 'make release 2>&1 | tee \"/tmp/release-1.log\"'",
    '69576 tee /tmp/release-1.log',
    '70001 tee -a out.log',
  ].join('\n')

  expect(teeTargets(processes)).toEqual(['/tmp/release-1.log', 'out.log'])
  expect(teeTargets('')).toEqual([])
})
