// Typed IPC layer: frontend → daemon via Tauri `invoke` commands, daemon →
// frontend via the "daemon" event (JSON Msgs) and per-terminal binary Channels
// (raw PTY bytes). This is the only module that touches @tauri-apps/api; the rest
// of the UI speaks these typed helpers.

import { Channel, invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { DaemonMsg, DaemonStatus, WireBoardViewport, WireTile } from "./protocol";

// --- daemon → frontend -----------------------------------------------------

/** Subscribe to JSON daemon messages (restore/board_list/doc_opened/…). */
export function onDaemonMsg(handler: (msg: DaemonMsg) => void): Promise<UnlistenFn> {
  return listen<DaemonMsg>("daemon", (e) => handler(e.payload));
}

/** Subscribe to connection status (connected/detached + reason). */
export function onDaemonStatus(handler: (status: DaemonStatus) => void): Promise<UnlistenFn> {
  return listen<DaemonStatus>("daemon-status", (e) => handler(e.payload));
}

/**
 * Register the binary output sink for a terminal. Creates a Channel<ArrayBuffer>
 * the Rust bridge streams this terminal's raw PTY bytes onto, and wires it to
 * `onBytes` (feed straight into xterm.write). Must be called before/at spawn so no
 * output is missed.
 */
export async function attachTermOutput(
  termId: string,
  onBytes: (bytes: Uint8Array) => void,
): Promise<void> {
  const onOutput = new Channel<ArrayBuffer>();
  onOutput.onmessage = (buf) => onBytes(new Uint8Array(buf));
  await invoke("term_attach", { termId, onOutput });
}

// --- frontend → daemon -----------------------------------------------------
// Tauri converts camelCase JS arg keys to the snake_case Rust command params.

export function spawnTerm(opts: {
  termId: string;
  cols: number;
  rows: number;
  cwd?: string;
  cmd?: string[];
  boardId?: string;
}): Promise<void> {
  return invoke("spawn_term", {
    termId: opts.termId,
    cols: opts.cols,
    rows: opts.rows,
    cwd: opts.cwd ?? null,
    cmd: opts.cmd ?? null,
    boardId: opts.boardId ?? null,
  });
}

export function termInput(termId: string, data: string): Promise<void> {
  return invoke("term_input", { termId, data });
}

export function termResize(termId: string, cols: number, rows: number): Promise<void> {
  return invoke("term_resize", { termId, cols, rows });
}

export function termClose(termId: string): Promise<void> {
  return invoke("term_close", { termId });
}

/** Release a terminal's output channel + pending buffer in the bridge (no daemon
 * message). Called when a TerminalCard unmounts so the IpcChannel doesn't leak. */
export function detachTermOutput(termId: string): Promise<void> {
  return invoke("term_detach", { termId });
}

export function docOpen(path: string, termId?: string, boardId?: string): Promise<void> {
  return invoke("doc_open", { path, termId: termId ?? null, boardId: boardId ?? null });
}

export function docRead(path: string): Promise<void> {
  return invoke("doc_read", { path });
}

export function docClose(path: string): Promise<void> {
  return invoke("doc_close", { path });
}

/** Read a doc's markdown content for rendering (the UI reads files itself). */
export function readDoc(path: string): Promise<string> {
  return invoke("read_doc", { path });
}

/** Signal the bridge that daemon listeners are registered, so it replays the
 * status/board_list/restore emitted before the webview mounted (startup race). */
export function frontendReady(): void {
  void invoke("frontend_ready").catch(() => {});
}

/**
 * Persist the full board layout (tiles + viewport) to the daemon — the v4
 * whiteboard `layout` message. Fire-and-forget; the daemon stores it and replays
 * it as `restore`. `tiles` carry snake_case wire keys (`term_id`) and integer `z`
 * so they deserialize straight into the Rust `Tile` struct. Continuous pan/zoom
 * is debounced by the caller; discrete gestures flush immediately.
 */
export function persistLayout(
  dock: string[],
  tiles: WireTile[],
  board: WireBoardViewport | null,
  boardId: string | null,
): Promise<void> {
  return invoke("persist_layout", { dock, tiles, board, boardId });
}

export function boardSwitch(boardId: string): Promise<void> {
  return invoke("board_switch", { boardId });
}

export function boardCreate(): Promise<void> {
  return invoke("board_create");
}

export function boardRename(boardId: string, name: string): Promise<void> {
  return invoke("board_rename", { boardId, name });
}

export function boardDelete(boardId: string): Promise<void> {
  return invoke("board_delete", { boardId });
}
