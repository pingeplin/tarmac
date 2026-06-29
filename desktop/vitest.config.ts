import { defineConfig } from "vitest/config";

// The ported TarmacKit logic in src/kit/ is pure value logic (no DOM), so the
// default node environment is correct. UI components (jsdom) get their own
// config later if/when they need DOM-based tests.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
