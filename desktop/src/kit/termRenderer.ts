// Pure renderer-state machine for terminal cards. No xterm or DOM imports.
// The shell (TerminalCard.tsx) owns the WebGL addon lifecycle; this module
// owns every decision and state transition so they are unit-testable.

export type RendererKind = "webgl" | "canvas";

export interface RendererState {
  kind: RendererKind;
  webglDisabled: boolean;
}

export const INITIAL_RENDERER_STATE: RendererState = {
  kind: "canvas",
  webglDisabled: false,
};

export function shouldAttemptWebgl(
  state: RendererState,
  supported: boolean,
): boolean {
  return supported && state.kind !== "webgl" && !state.webglDisabled;
}

export function onWebglLoaded(state: RendererState): RendererState {
  return { ...state, kind: "webgl" };
}

export function onContextLoss(_state: RendererState): RendererState {
  return { kind: "canvas", webglDisabled: true };
}

export function onWebglUnavailable(_state: RendererState): RendererState {
  return { kind: "canvas", webglDisabled: true };
}
