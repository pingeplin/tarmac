// Breeze (Ghostty/KDE) palette + fonts, ported from TarmacApp/Theme.swift and the
// ANSI-16 set in AppController.makeSession. These drive the board chrome (CSS vars
// in theme.css) and the xterm.js terminal theme below.

export const palette = {
  bg0: "#24282c",
  bg1: "#2b3036",
  bg2: "#353b41",
  bg3: "#3e444b",
  termBg: "#31363b",
  termFg: "#ced2d6",
  line: "#474e55",
  lineSoft: "#3d434a",
  text: "#eff0f1",
  muted: "#b9bfc4",
  faint: "#7f8c8d",
  agent: "#1abc9c",
  agentDim: "rgba(26,188,156,0.16)",
  liftBorder: "#5a626a",
  focusBorder: "rgba(26,188,156,0.5)",
  primeHeaderBg: "#3a4046",
  amber: "#fdbc4b",
  amberDim: "rgba(253,188,75,0.16)",
  ok: "#1cdc9a",
} as const;

// repo dot colors (FNV-1a index 0..3); matches Theme.repoColors and the daemon's
// repo_color_index, so a doc's color is identical to what users saw in the Swift app.
export const repoColors = ["#f67400", "#11d116", "#1d99f3", "#9b59b6"] as const;

// Terminal interior face: JetBrainsMono Nerd Font Mono if installed (Nerd Font
// powerline/icon glyphs), else IBM Plex Mono / system mono. Name resolution
// against an installed font, mirroring Theme.termFont.
export const termFontFamily =
  "'JetBrainsMono Nerd Font Mono', 'JetBrainsMonoNFM', 'IBM Plex Mono', ui-monospace, monospace";
export const chromeFontFamily = "'IBM Plex Mono', ui-monospace, SFMono-Regular, monospace";
export const termFontSize = 16; // world points at 100% zoom (crib §3)

// The 16 ANSI Breeze colors (AppController.breezeAnsiColors), in xterm theme order.
export const xtermTheme = {
  background: palette.termBg,
  foreground: palette.termFg,
  cursor: palette.text,
  cursorAccent: palette.termBg,
  selectionBackground: "rgba(26,188,156,0.3)", // Theme.agent @ 0.3
  black: "#232627",
  red: "#ed1515",
  green: "#11d116",
  yellow: "#f67400",
  blue: "#1d99f3",
  magenta: "#9b59b6",
  cyan: "#1abc9c",
  white: "#fcfcfc",
  brightBlack: "#7f8c8d",
  brightRed: "#c0392b",
  brightGreen: "#1cdc9a",
  brightYellow: "#fdbc4b",
  brightBlue: "#3daee9",
  brightMagenta: "#8e44ad",
  brightCyan: "#16a085",
  brightWhite: "#ffffff",
} as const;
