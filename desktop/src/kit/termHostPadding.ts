// Pure helper for the .term-host padding string used in the rasterScale
// useLayoutEffect. Must stay in sync with .term-host in theme.css.

export const HOST_PADDING_V_PX = 8;
export const HOST_PADDING_H_PX = 10;
export const HOST_PADDING_BOTTOM_PX = 16;

/** Returns the CSS padding shorthand for .term-host at a given rasterScale. */
export function termHostPadding(rs: number): string {
  return `${HOST_PADDING_V_PX * rs}px ${HOST_PADDING_H_PX * rs}px ${HOST_PADDING_BOTTOM_PX * rs}px`;
}
