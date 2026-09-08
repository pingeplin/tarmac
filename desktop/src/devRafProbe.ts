// Dev-only install site for the host-page rAF counter (#105). `main.tsx` imports
// it FIRST, so the wrappers precede every other module body.
//
// What that placement actually buys, since the reading rests on it: the counter
// sees every request made *through the global*, whenever the caller's module was
// evaluated — no dependency here aliases or binds `requestAnimationFrame`
// (audited across react-dom, scheduler, xterm + addons, marked,
// @tauri-apps/api), and the two scripts that do run ahead of this module in dev,
// Vite's client and @vitejs/plugin-react's refresh preamble, request no frames
// at all. Re-check that on a Vite or dependency bump: a request outstanding
// before the install is invisible, and invisible reads as *idle* — the one
// direction that would falsely confirm the regime this instrument exists to test.
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
