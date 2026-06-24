// Pure predicate: returns true when the keystroke belongs to an in-flight IME
// composition and must pass through to xterm untouched (no preventDefault /
// stopPropagation). Two indicators are checked:
//   • e.isComposing — the standard DOM compositionstart/end flag.
//   • e.keyCode === 229 — the legacy sentinel some IMEs (notably Korean, older
//     Android Chrome) still emit during composition even on modern engines.
// Either condition is sufficient.

export function isComposingKey(e: { isComposing?: boolean; keyCode?: number }): boolean {
  return e.isComposing === true || e.keyCode === 229;
}
