/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_TARMAC_DEV_LABEL?: string;
  /** Dev opt-in for the host-page rAF counter (#105) — see src/devRafProbe.ts. */
  readonly VITE_TARMAC_RAF_PROBE?: string;
}
