import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { logOf, parseLog, STEPS, teeTarget } from './progress'

const run = atom({ plugin: 'release-progress', key: 'run' } as const, null)
const isHidden = atom(
  { plugin: 'release-progress', key: 'isHidden' } as const,
  false,
)

const poll = async ($: EngineInterface) => {
  const now = await read($, run)

  if (now === null || now.status !== 'running') {
    return
  }

  const text = await $.fs.read(now.log).catch(() => null)

  if (text === null) {
    return
  }

  const seen = parseLog(text)
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
  await poll($)
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
        await track($, log)
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

    if (log !== null) {
      await track($, log)

      return { text: `Following ${log}` }
    }

    await update($, isHidden, () => false)
    const now = await read($, run)

    return {
      text:
        now === null
          ? 'No release is running. Pass its log path: /release-progress <log>'
          : `No release is running. Showing the last one: ${now.log}`,
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await read($, run)

    if (e.props.hasSurvey || now === null || (await read($, isHidden))) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const isFailed = now.status === 'failed'
    const current = STEPS[now.step]
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
                <Text bold color={isFailed ? 'red' : 'yellow'}>
                  {isFailed ? '✗' : '▸'} {name}{' '}
                </Text>
              ),
            )}
          {!isWide && (
            <Text color={isFailed ? 'red' : current ? 'yellow' : 'green'}>
              {current === undefined
                ? '✓ published '
                : `${isFailed ? '✗' : '▸'} ${current} ${now.step + 1}/${STEPS.length} `}
            </Text>
          )}
          <Button
            key="hide"
            label="Hide"
            role="dismiss"
            onPress={() => update($, isHidden, () => true)}
          />
        </Box>
        <Text dimColor={!isFailed} color={isFailed ? 'red' : undefined} wrap="truncate-end">
          {now.line}
        </Text>
      </Box>
    )
  })
}
