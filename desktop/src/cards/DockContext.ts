import { createContext } from "react";

/** Lets a TerminalCard reparent its xterm host node into the shared dock pane and
 *  register a focus handle, without prop-drilling through Board. The host node is
 *  moved imperatively (appendChild) so React never owns it as a child — no remount,
 *  scrollback + pty survive. */
export interface DockContextValue {
  /** The ACTIVE board's docked term id (the single shared pane). null = nothing docked. */
  dockedTermId: string | null;
  /** The dock pane body element to appendChild the host into when docked. */
  dockSlot: HTMLElement | null;
  /** Register a focus handle so App can focus a terminal on dock / cycle. */
  registerTerm(termId: string, handle: { focus(): void }): void;
  unregisterTerm(termId: string): void;
}

export const DockContext = createContext<DockContextValue>({
  dockedTermId: null,
  dockSlot: null,
  registerTerm: () => {},
  unregisterTerm: () => {},
});
