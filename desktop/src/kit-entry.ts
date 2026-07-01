// Standalone kit entry point — bundled by desktop/scripts/build-kit.mjs into a
// single IIFE (window.TarmacKit) for /design-sync. Re-exports the 10 in-scope
// presentational components (8 from ui/ + CardShell/DocCard from cards/) plus a
// tiny `mount(name, props, el)` helper the per-component preview HTML calls.
// Deliberately does NOT export TitleBarChip (dead code, dropped per the design
// doc — see docs/designs/2607.0001_tarmac_ui_kit_design_sync_export.md).

import { createRoot } from "react-dom/client";
import { createElement, type ComponentType } from "react";

import { CardShell } from "./cards/CardShell";
import { DocCard } from "./cards/DocCard";
import { BoardSwitcher } from "./ui/BoardSwitcher";
import { CycleHud } from "./ui/CycleHud";
import { DockPane } from "./ui/DockPane";
import { MinimapOverlay } from "./ui/MinimapOverlay";
import { OffscreenHints } from "./ui/OffscreenHints";
import { StatusBar } from "./ui/StatusBar";
import { ToastOverlay } from "./ui/ToastOverlay";
import { ZoomControl } from "./ui/ZoomControl";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const components: Record<string, ComponentType<any>> = {
  CardShell,
  DocCard,
  BoardSwitcher,
  CycleHud,
  DockPane,
  MinimapOverlay,
  OffscreenHints,
  StatusBar,
  ToastOverlay,
  ZoomControl,
};

export type ComponentName = keyof typeof components;

/** Renders component `name` with `props` into `el` via a React 19 root. Called
 * once per preview HTML (see dist-kit/components/<name>/index.html). */
export function mount(name: string, props: Record<string, unknown>, el: HTMLElement): void {
  const Component = components[name];
  if (!Component) {
    throw new Error(`TarmacKit.mount: unknown component "${name}"`);
  }
  createRoot(el).render(createElement(Component, props));
}

export {
  CardShell,
  DocCard,
  BoardSwitcher,
  CycleHud,
  DockPane,
  MinimapOverlay,
  OffscreenHints,
  StatusBar,
  ToastOverlay,
  ZoomControl,
};
