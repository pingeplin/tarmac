// Whether a resize press flushes the page selection. The flush is for a
// highlighted Range in the page, such as selected doc prose (markdown doc cards
// share the document). A focused textarea owns the selection instead: a
// terminal's is xterm's hidden one, holding a caret or, after a right-click, the
// word's Range. Flushing that leaves the terminal focused while WebKit fires no
// `beforeinput`, the only path plain keys take to the PTY since #160 (#162).

export function flushesOnResize(s: { type: string; focusTag: string | undefined }): boolean {
  return s.type === "Range" && s.focusTag !== "TEXTAREA";
}
