import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [react()],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },

  // Split the heavy vendor deps out of the single app chunk. This is build
  // hygiene, not a load optimization: the bundle is served from local disk in
  // a WKWebView, so chunk size has no runtime cost — it just silences Vite's
  // 500 kB warning and keeps rarely-changing vendor code in its own cacheable
  // chunks. The WebGL renderer is its own chunk because xterm core + webgl
  // together exceed 500 kB; separating them keeps every chunk under the line.
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          react: ["react", "react-dom"],
          xterm: [
            "@xterm/xterm",
            "@xterm/addon-fit",
            "@xterm/addon-unicode11",
            "@xterm/addon-web-links",
          ],
          "xterm-webgl": ["@xterm/addon-webgl"],
          marked: ["marked"],
        },
      },
    },
  },
}));
