import { expect, test } from 'claude-code/testing'
import type { On, RenderElement } from 'claude-code'

const BAND = {
  plugin: 'release-progress',
  surface: 'terminal',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const engineBand = (on: On) =>
  on(
    'ui.render',
    { component: 'AbovePrompt' },
    ($, e) => h($.ui.resolve(e).Text, null, 'engine band') as RenderElement,
  )

const follow = { command: 'release-progress', args: '/tmp/release.log' }

test('the band is quiet until a release is followed', async ($, on) => {
  engineBand(on)
  const ui = await $.ui.mount(BAND)

  expect(await ui.find({ text: 'engine band' })).toBeDefined()
})

test('a followed log draws the step it reached and its last line', async ($, on) => {
  engineBand(on)
  on('fs.read', () => ({
    value: ['==> signing (identity: X)', '==> notarizing', '  status: In Progress'].join('\n'),
  }))
  await $.command.run({
    ...follow,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })
  const ui = await $.ui.mount(BAND)

  expect(await ui.find({ type: 'Text', text: '✓ sign' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '▸ notarize' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '· verify' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'status: In Progress' })).toBeDefined()

  await ui.press({ key: 'hide' })
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
})

test('a narrow band names only the current step', async ($, on) => {
  on('fs.read', () => ({ value: '==> Homebrew tap\n' }))
  await $.command.run({
    ...follow,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 60 },
  })
  const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, bodyColumns: 60 } })

  expect(await ui.find({ type: 'Text', text: '▸ tap 7/8' })).toBeDefined()
})

test('a release command with a tee is followed by itself', async ($, on) => {
  on('fs.read', () => ({ value: '==> released v9.9.9\n' }))
  on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '' } }) as never)
  await $.tool.call({
    tool: 'Bash',
    command: 'VERSION=9.9.9 make release 2>&1 | tee /tmp/r.log',
  } as never)
  const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, bodyColumns: 60 } })

  expect(await ui.find({ type: 'Text', text: '✓ published' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'released v9.9.9' })).toBeDefined()
})
