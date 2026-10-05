import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { isTeeing, logOf, parseLog, STEPS, teeTarget } from './progress'

const run = atom({ plugin: 'release-progress', key: 'run' } as const, null)
const isHidden = atom(
  { plugin: 'release-progress', key: 'isHidden' } as const,
  false,
)

const ENDED = 'the release ended without finishing'

// A killed release leaves no marker in its log: only its tee going away says so.
const isAlive = async ($: EngineInterface, log: string) => {
  const found = await $.process.run(['pgrep', '-fl', 'tee ']).catch(() => null)

  return found === null || isTeeing(found.stdout, log)
}

const poll = async ($: EngineInterface) => {
  const now = await read($, run)

  if (now === null || now.status !== 'running') {
    return
  }

  // Asked before the read: a tee already gone has written all it ever will.
  const isOver = !(await isAlive($, now.log))
  const text = await $.fs.read(now.log).catch(() => null)

  if (text === null) {
    return
  }

  const parsed = parseLog(text)
  const seen =
    parsed.status === 'running' && isOver
      ? { ...parsed, status: 'failed' as const, line: ENDED }
      : parsed
  const isSame =
    seen.step === now.step &&
    seen.status === now.status &&
    seen.line === now.line &&
    seen.version === now.version

  if (isSame) {
    return
  }

  await update($, run, () => ({ ...seen, log: now.log }))

  if (seen.status === 'done') {
    $.ui.toast(`Release ${seen.version ?? ''} is published`)
  }

  if (seen.status === 'failed') {
    $.ui.toast(`Release failed at ${STEPS[seen.step]}: ${seen.line}`)
  }
}

const track = async ($: EngineInterface, log: string) => {
  await update($, run, () => ({ ...parseLog(''), log }))
  await update($, isHidden, () => false)
}

const follow = async ($: EngineInterface, log: string) => {
  await track($, log)
  await poll($)
  const now = await read($, run)

  return now === null || now.status === 'running'
    ? `Following ${log}`
    : `That release is over: ${now.line}`
}

const discover = async ($: EngineInterface) => {
  const found = await $.process
    .run(['pgrep', '-fl', 'tee .*release'])
    .catch(() => null)

  return found === null ? null : teeTarget(found.stdout)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'release-progress',
      description:
        'Follow a release log in the band: [log path], or "off" to hide',
    })

    const now = await read($, run)

    if (now === null || now.status !== 'running') {
      const log = await discover($)

      if (log !== null) {
        await follow($, log)
      }
    }

    $.clock.every(2000, () => void poll($))

    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    const log = logOf(e.command)

    if (ran.deny === undefined && log !== null) {
      await track($, log)
      // A resumed release tees over its last log: read it once the tee has cut it.
      $.clock.after(1000, () => void poll($))
    }

    return ran
  })

  on('command.run', { command: 'release-progress' }, async ($, e) => {
    const asked = e.args.trim()

    if (asked === 'off') {
      await update($, isHidden, () => true)

      return { text: 'Release progress hidden.' }
    }

    const log = asked === '' ? await discover($) : asked

    return {
      text: log === null ? 'No release is running.' : await follow($, log),
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await read($, run)

    if (
      now === null ||
      now.status !== 'running' ||
      e.props.hasSurvey ||
      (await read($, isHidden))
    ) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const isWide = e.props.bodyColumns >= 96

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>release {now.version ?? ''} </Text>
          {isWide &&
            STEPS.map((name, at) =>
              at < now.step ? (
                <Text color="green">✓ {name} </Text>
              ) : at > now.step ? (
                <Text dimColor>· {name} </Text>
              ) : (
                <Text bold color="yellow">
                  ▸ {name}{' '}
                </Text>
              ),
            )}
          {!isWide && (
            <Text color="yellow">
              ▸ {STEPS[now.step]} {now.step + 1}/{STEPS.length}{' '}
            </Text>
          )}
          <Button
            key="hide"
            label="Hide"
            role="dismiss"
            onPress={() => update($, isHidden, () => true)}
          />
        </Box>
        <Text dimColor wrap="truncate-end">
          {now.line}
        </Text>
      </Box>
    )
  })
}
