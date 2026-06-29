import { describe, it, expect } from "vitest";
import { TermBoardIndex } from "./termBoardIndex";

// Port of TermBoardIndexTests.swift.
describe("TermBoardIndex", () => {
  it("assign then lookup", () => {
    const idx = new TermBoardIndex();
    idx.assign("t1", "board-0");
    expect(idx.board("t1")).toBe("board-0");
  });

  it("unknown term is undefined", () => {
    const idx = new TermBoardIndex();
    expect(idx.board("nope")).toBeUndefined();
  });

  it("reassign moves the term to the new board", () => {
    const idx = new TermBoardIndex();
    idx.assign("t1", "board-0");
    idx.assign("t1", "board-1");
    expect(idx.board("t1")).toBe("board-1");
    expect(idx.terms("board-0")).toEqual([]);
    expect(idx.terms("board-1")).toEqual(["t1"]);
  });

  it("remove orphans the term", () => {
    const idx = new TermBoardIndex();
    idx.assign("t1", "board-0");
    idx.remove("t1");
    expect(idx.board("t1")).toBeUndefined();
  });

  it("removeBoard drops all its terms", () => {
    const idx = new TermBoardIndex();
    idx.assign("t1", "board-0");
    idx.assign("t2", "board-0");
    idx.assign("t3", "board-1");
    idx.removeBoard("board-0");
    expect(idx.board("t1")).toBeUndefined();
    expect(idx.board("t2")).toBeUndefined();
    expect(idx.board("t3")).toBe("board-1");
  });

  it("two boards keep distinct term sets", () => {
    const idx = new TermBoardIndex();
    idx.assign("t1", "board-0");
    idx.assign("t2", "board-1");
    expect(idx.terms("board-0")).toEqual(["t1"]);
    expect(idx.terms("board-1")).toEqual(["t2"]);
  });
});
