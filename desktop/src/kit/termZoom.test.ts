import { describe, it, expect } from "vitest";
import { termWrapperBox, termCardVars, termInnerBox, termBcrScale } from "./termZoom";
import { docWrapperBox } from "./docZoom";
import { worldToView } from "./boardTransform";

// --- S6 helper (mirrors docZoom.test.ts) -----------------------------------

function evalCalcPx(expr: string, vars: Record<string, string>): number {
  const inner = expr.match(/^calc\((.+)\)$/)?.[1] ?? expr;
  const substituted = inner.replace(/var\(--([a-z-]+)\)/g, (_, name: string) => {
    const key = `--${name}`;
    if (!(key in vars)) throw new Error(`unknown CSS var ${key}`);
    return vars[key];
  });
  const noUnits = substituted.replace(/(-?\d+(?:\.\d+)?)px/g, "$1");
  // eslint-disable-next-line no-new-func
  return Function(`"use strict"; return (${noUnits})`)() as number;
}

function splitTranslateArgs(transformStr: string): [string, string] {
  const prefix = "translate(";
  if (!transformStr.startsWith(prefix) || !transformStr.endsWith(")")) {
    throw new Error(`expected translate(...), got: ${transformStr}`);
  }
  const inner = transformStr.slice(prefix.length, -1);
  let depth = 0;
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === "(") depth++;
    else if (inner[i] === ")") depth--;
    else if (inner[i] === "," && depth === 0) {
      return [inner.slice(0, i), inner.slice(i + 1)];
    }
  }
  throw new Error("no top-level comma in translate args");
}

function evalWrapperTranslate(
  transformStr: string,
  vars: Record<string, string>,
): { x: number; y: number } {
  const [xExpr, yExpr] = splitTranslateArgs(transformStr);
  return { x: evalCalcPx(xExpr, vars), y: evalCalcPx(yExpr, vars) };
}

// ---------------------------------------------------------------------------

describe("S1 — outer wrapper equals doc formula (translate-only, no scale)", () => {
  it("termWrapperBox() is string-for-string identical to docWrapperBox()", () => {
    expect(termWrapperBox()).toStrictEqual(docWrapperBox());
  });

  it("transform has no scale( — break: adding scale(var(--zoom)) fails this", () => {
    expect(termWrapperBox().transform).not.toMatch(/scale\(/);
  });
});

describe("S2 — outer wrapper has no willChange", () => {
  it("willChange key is absent — break: adding willChange:'transform' fails this", () => {
    expect("willChange" in termWrapperBox()).toBe(false);
  });
});

describe("S3 — inner box is zoom-free (no --zoom in width/height)", () => {
  it("width is exactly 'var(--card-w)' — break: calc(...*var(--zoom)) fails this", () => {
    expect(termInnerBox().width).toBe("var(--card-w)");
  });

  it("height is exactly 'var(--card-h)'", () => {
    expect(termInnerBox().height).toBe("var(--card-h)");
  });

  it("width does not reference --zoom", () => {
    expect(termInnerBox().width).not.toMatch(/var\(--zoom\)/);
  });

  it("height does not reference --zoom", () => {
    expect(termInnerBox().height).not.toMatch(/var\(--zoom\)/);
  });
});

describe("S4 — inner box carries the sole scale (exact form, no willChange)", () => {
  it("transform is exactly 'scale(var(--zoom))' — break: scale(calc(var(--zoom)/1)) fails", () => {
    expect(termInnerBox().transform).toBe("scale(var(--zoom))");
  });

  it("transformOrigin is '0 0'", () => {
    expect(termInnerBox().transformOrigin).toBe("0 0");
  });

  it("willChange key is absent", () => {
    expect("willChange" in termInnerBox()).toBe(false);
  });
});

describe("S5 — termCardVars produces --card-* px strings", () => {
  it("returns all four custom properties with px suffix — break: dropping px fails", () => {
    expect(termCardVars({ x: 100, y: 200, w: 360, h: 480 })).toStrictEqual({
      "--card-x": "100px",
      "--card-y": "200px",
      "--card-w": "360px",
      "--card-h": "480px",
    });
  });
});

describe("S6 — outer origin projects via worldToView (eval actual transform string)", () => {
  it("at zoom 2 the eval'd translate matches worldToView — break: wrong sign on --world-ty diverges", () => {
    const zoom = 2, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom;
    const ty = viewH / 2 - cy * zoom;

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
    };

    const { transform } = termWrapperBox();
    const { x: screenX, y: screenY } = evalWrapperTranslate(transform, vars);

    const proj = worldToView(
      { x: cardX, y: cardY },
      zoom,
      { x: cx, y: cy },
      { x: viewW / 2, y: viewH / 2 },
    );

    expect(screenX).toBeCloseTo(proj.x);
    expect(screenY).toBeCloseTo(proj.y);
  });

  it("at zoom 0.5 the eval'd translate matches worldToView", () => {
    const zoom = 0.5, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom;
    const ty = viewH / 2 - cy * zoom;

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
    };

    const { transform } = termWrapperBox();
    const { x: screenX, y: screenY } = evalWrapperTranslate(transform, vars);

    const proj = worldToView(
      { x: cardX, y: cardY },
      zoom,
      { x: cx, y: cy },
      { x: viewW / 2, y: viewH / 2 },
    );

    expect(screenX).toBeCloseTo(proj.x);
    expect(screenY).toBeCloseTo(proj.y);
  });
});

describe("S7 — BCR scale product undocked", () => {
  it("zoom=2, rs=1 → 2 — break: ignoring rs returns zoom, passes this case", () => {
    expect(termBcrScale(2, 1, false)).toBe(2);
  });

  it("zoom=2, rs=2 → 1 — break: ignoring rs (return zoom) returns 2, not 1", () => {
    expect(termBcrScale(2, 2, false)).toBe(1);
  });

  it("zoom=3, rs=1.5 → 2 — break: ignoring rs diverges", () => {
    expect(termBcrScale(3, 1.5, false)).toBeCloseTo(2);
  });
});

describe("S8 — BCR docked always returns 1", () => {
  it("docked zoom=2, rs=1 → 1 — break: dropping docked guard returns zoom/rs=2", () => {
    expect(termBcrScale(2, 1, true)).toBe(1);
  });

  it("docked zoom=3, rs=1 → 1", () => {
    expect(termBcrScale(3, 1, true)).toBe(1);
  });

  it("docked zoom=0.5, rs=1 → 1", () => {
    expect(termBcrScale(0.5, 1, true)).toBe(1);
  });
});
