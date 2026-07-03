// Thin wrapper around @tauri-apps/plugin-opener's openUrl, so card click
// handlers depend on this narrow interface rather than the plugin directly.
// Untested per this project's "app-layer isn't unit-tested" convention.

import { openUrl } from "@tauri-apps/plugin-opener";

/** Open `url` in the OS default browser via the Tauri opener plugin. */
export function openExternal(url: string): Promise<void> {
  return openUrl(url);
}
