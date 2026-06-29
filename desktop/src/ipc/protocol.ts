// TypeScript mirrors of the daemon→app message payloads. These match the JSON the
// Rust bridge emits on the "daemon" Tauri event (serde of tarmac_protocol::Msg,
// tag = "t", snake_case variant tags; struct fields are already snake_case on the
// wire). `Output` is NOT here — PTY bytes stream over a per-terminal binary Channel,
// never as JSON.

/** Wire doc entry (tarmac_protocol::DocEntry) — snake_case as it arrives. */
export interface WireDocEntry {
  path: string;
  via: string;
  repo?: string | null;
  repo_root?: string | null;
  repo_color?: number | null;
  read: boolean;
  last_changed_ms?: number | null;
  last_opened_ms?: number | null;
  term_id?: string | null;
}

/** Wire layout tile (tarmac_protocol::Tile). */
export interface WireTile {
  kind: string;
  path?: string | null;
  x?: number | null;
  y?: number | null;
  w?: number | null;
  h?: number | null;
  z?: number | null;
  loose?: boolean | null;
  shelf?: boolean | null;
  term_id?: string | null;
}

export interface WireBoardViewport {
  zoom: number;
  cx: number;
  cy: number;
}

export interface WireBoardMeta {
  board_id: string;
  name?: string | null;
  running?: number | null;
}

// The daemon→app messages, discriminated on `t`. Unknown messages decode to
// { t: string } and are ignored by the handler's default branch.
export type DaemonMsg =
  | { t: "hello_ok"; v: number }
  | { t: "err"; msg: string }
  | {
      t: "restore";
      docs: WireDocEntry[];
      tiles?: WireTile[];
      board?: WireBoardViewport | null;
      board_id?: string | null;
      live_terms?: string[];
    }
  | { t: "exit"; term_id: string; code?: number | null }
  | ({ t: "doc_opened" } & WireDocEntry)
  | { t: "file_event"; path: string; mtime_ms: number }
  | { t: "term_proc"; term_id: string; name: string; pid?: number | null }
  | { t: "bell"; term_id: string }
  | { t: "board_list"; boards: WireBoardMeta[]; active: string };
// Unknown / additive messages (e.g. ack) arrive cast to DaemonMsg and fall to the
// handler's default branch — the closed union above keeps `switch` narrowing exact.

export interface DaemonStatus {
  connected: boolean;
  reason?: string | null;
}

/** Map a wire doc entry (snake_case) to the camelCase RestoreDoc the ported
 * DocStore consumes. Kept at the IPC boundary so the kit stays wire-agnostic. */
export interface RestoreDoc {
  path: string;
  via: string;
  repo?: string;
  repoRoot?: string;
  repoColor?: number;
  read: boolean;
  lastChangedMs?: number;
  lastOpenedMs?: number;
  termId?: string;
}

export function toRestoreDoc(d: WireDocEntry): RestoreDoc {
  return {
    path: d.path,
    via: d.via,
    repo: d.repo ?? undefined,
    repoRoot: d.repo_root ?? undefined,
    repoColor: d.repo_color ?? undefined,
    read: d.read,
    lastChangedMs: d.last_changed_ms ?? undefined,
    lastOpenedMs: d.last_opened_ms ?? undefined,
    termId: d.term_id ?? undefined,
  };
}
