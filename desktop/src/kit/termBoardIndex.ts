// Port of TarmacKit/TermBoardIndex.swift — the `term_id → board_id` ownership
// index (M3). Every terminal belongs to exactly one board, so daemon frames keyed
// by the globally-unique term_id (output / exit / term_proc / bell) route to the
// owning board even when it is backgrounded, and `tarmac open` provenance + board
// teardown scope per board. Swift modelled this as a mutating struct; here it is a
// small class with the same invariants (last assignment wins; no two boards share
// a term_id).

export class TermBoardIndex {
  private owner = new Map<string, string>();

  /** Records that `termId` belongs to `boardId` (set at spawn). Re-assigning an
   * existing term overwrites its owner — last assignment wins. */
  assign(termId: string, boardId: string): void {
    this.owner.set(termId, boardId);
  }

  /** Drops a single terminal (on its exit). */
  remove(termId: string): void {
    this.owner.delete(termId);
  }

  /** Drops every terminal owned by `boardId` (board teardown / delete). */
  removeBoard(boardId: string): void {
    for (const [termId, owner] of this.owner) {
      if (owner === boardId) this.owner.delete(termId);
    }
  }

  /** The board that owns `termId`, or undefined when unknown. */
  board(of: string): string | undefined {
    return this.owner.get(of);
  }

  /** Every terminal owned by `boardId`, in no particular order. */
  terms(of: string): string[] {
    const result: string[] = [];
    for (const [termId, owner] of this.owner) {
      if (owner === of) result.push(termId);
    }
    return result;
  }
}
