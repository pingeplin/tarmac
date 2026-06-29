import { describe, it, expect } from "vitest";
import {
  deriveRasterScale,
  RASTER_SCALE_STEP,
  RASTER_SCALE_CAP,
} from "./rasterScale";

describe("deriveRasterScale", () => {
  it("returns 1 at zoom = 1 (no oversampling at native)", () => {
    expect(deriveRasterScale(1)).toBe(1);
  });

  it("returns 1 below zoom = 1 (downscale path is already crisp)", () => {
    expect(deriveRasterScale(0.1)).toBe(1);
    expect(deriveRasterScale(0.5)).toBe(1);
    expect(deriveRasterScale(0.99)).toBe(1);
  });

  it("snaps to the next RASTER_SCALE_STEP increment above 1", () => {
    // zoom 1.01 → ceil(1.01 / 0.5) * 0.5 = ceil(2.02) * 0.5 = 3 * 0.5 = 1.5
    expect(deriveRasterScale(1.01)).toBe(1.5);
    expect(deriveRasterScale(1.5)).toBe(1.5);
    expect(deriveRasterScale(1.51)).toBe(2.0);
    expect(deriveRasterScale(2.0)).toBe(2.0);
    expect(deriveRasterScale(2.01)).toBe(2.5);
    expect(deriveRasterScale(2.5)).toBe(2.5);
    expect(deriveRasterScale(2.51)).toBe(3.0);
  });

  it("caps at RASTER_SCALE_CAP regardless of zoom", () => {
    expect(deriveRasterScale(3.0)).toBe(RASTER_SCALE_CAP);
    expect(deriveRasterScale(3.1)).toBe(RASTER_SCALE_CAP);
    expect(deriveRasterScale(100)).toBe(RASTER_SCALE_CAP);
  });

  it("step boundary: exactly at step multiples stays on that step", () => {
    for (let n = 2; n <= RASTER_SCALE_CAP / RASTER_SCALE_STEP; n++) {
      const zoom = n * RASTER_SCALE_STEP;
      // zoom > 1, so oversampling applies; should snap to itself
      if (zoom > 1 && zoom <= RASTER_SCALE_CAP) {
        expect(deriveRasterScale(zoom)).toBe(zoom);
      }
    }
  });
});
