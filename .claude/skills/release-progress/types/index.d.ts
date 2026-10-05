export type Progress = {
  step: number
  status: 'running' | 'done' | 'failed'
  line: string
  version: string | null
}

export type Run = Progress & { log: string }

declare module 'claude-code' {
  interface PluginState {
    'release-progress': { run: Run | null; isHidden: boolean }
  }
}
