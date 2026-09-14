import { describe, it, expect } from "vitest";
import { binaryBytes } from "./termBinaryInput";

describe("binaryBytes", () => {
  it("maps each char of a binary string to one byte", () => {
    expect(binaryBytes("\x00\x7f\x80\xff")).toEqual([0x00, 0x7f, 0x80, 0xff]);
  });

  it("keeps a default-encoded mouse report past column 95 byte-for-byte", () => {
    // Left press at column 100, row 3: CSI M, then 32 + button, 32 + col, 32 + row.
    expect(binaryBytes("\x1b[M\x20\x84\x23")).toEqual([0x1b, 0x5b, 0x4d, 0x20, 0x84, 0x23]);
  });

  it("returns no bytes for an empty string", () => {
    expect(binaryBytes("")).toEqual([]);
  });
});
