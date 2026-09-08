// Dev-only install site for the host-page rAF counter (#105). `main.tsx` imports
// it FIRST, so the wrappers are in place before react-dom, xterm and App
// evaluate: none of them captures a scheduler at module-eval time today, but
// "installed before anything else loads" is the instrument's whole premise, and
// a side-effect module is the cheapest way to keep that true as deps change.
//
// Two flags, two jobs. `DEV` is the release guarantee — Vite replaces it with
// `false` in `vite build`, so the branch, this module and `kit/rafProbe.ts` all
// leave the shipped bundle. `VITE_TARMAC_RAF_PROBE` is the dev opt-in, so a
// plain `make run` still installs nothing; QA runs `VITE_TARMAC_RAF_PROBE=1 make
// run` (see `desktop/qa/raf-outstanding-qa.md`).

import { installRafProbe } from "./kit/rafProbe";

if (import.meta.env.DEV && import.meta.env.VITE_TARMAC_RAF_PROBE) {
  // The banner is the only thing the probe prints unasked: it is how QA knows
  // the flag reached the bundle, since a probe that never installed and a page
  // that holds no request read the same from the console.
  if (installRafProbe(window)) {
    console.info("[tarmac raf] probe installed — run __tarmacRafSample() to measure");
  }
}
