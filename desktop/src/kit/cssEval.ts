// Test-only evaluator for the CSS strings the zoom-layout modules emit. The
// wrapper box is authored as CSS text (docZoom/termZoom), so the only way to
// assert it PROJECTS correctly rather than merely matching a literal is to
// evaluate the real string. Only *.test.ts files import it, so Vite never
// bundles it.

/** Evaluate a `calc(...)`/`round(...)` px expression against a var table. */
function evalCalcPx(expr: string, vars: Record<string, string>): number {
  const inner = expr.match(/^calc\((.+)\)$/)?.[1] ?? expr;
  const substituted = inner.replace(/var\(--([a-z-]+)\)/g, (_, name: string) => {
    const key = `--${name}`;
    if (!(key in vars)) throw new Error(`unknown CSS var ${key}`);
    return vars[key];
  });
  const noUnits = substituted.replace(/(-?\d+(?:\.\d+)?)px/g, "$1");
  // CSS round(A,B) — the device-pixel snap in the wrapper transform. `calc`
  // survives as an inner call once round() wraps it; JS precedence already
  // matches CSS math, so it evaluates as identity.
  const round = (v: number, step: number): number => Math.round(v / step) * step;
  const calc = (v: number): number => v;
  // eslint-disable-next-line no-new-func
  return Function("round", "calc", `"use strict"; return (${noUnits})`)(round, calc) as number;
}

/** Split the two args of translate(A,B) respecting nested parens. */
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

/** The screen point a wrapper transform lands its box origin on. */
export function evalWrapperTranslate(
  transformStr: string,
  vars: Record<string, string>,
): { x: number; y: number } {
  const [xExpr, yExpr] = splitTranslateArgs(transformStr);
  return { x: evalCalcPx(xExpr, vars), y: evalCalcPx(yExpr, vars) };
}
