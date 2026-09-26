/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";
import { entryBudget, precompress } from "./js/build/plugins";

// Phoenix serves the page and the built files under /assets (see
// LongxWeb.Vite); in dev the browser loads scripts straight from this
// server, so it must be reachable from the phone too (LONGX_DEV_HOST).
const devHost = process.env.LONGX_DEV_HOST;

// what every page loads before anything shows: at 1.5 Mbps the 3.7 MB entry
// of 0.2.64 took 21 s (uncompressed) — the diagram renderer, the code editor
// and the settings pages load where they are used (import())
const ENTRY_BUDGET = 1_600_000;

export default defineConfig(({ command }) => ({
  base: command === "build" ? "/assets/" : "/",
  publicDir: false,
  server: {
    host: true,
    port: 7799,
    strictPort: true,
    cors: true,
    origin: devHost ? `http://${devHost}:7799` : undefined,
  },
  build: {
    manifest: true,
    outDir: "../priv/static/assets",
    assetsDir: ".",
    emptyOutDir: true,
    rollupOptions: { input: ["js/index.tsx"] },
  },
  resolve: { alias: { "@": path.resolve(__dirname, "js") } },
  plugins: [react(), tailwindcss(), entryBudget(ENTRY_BUDGET), precompress()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    include: ["js/**/*.test.{ts,tsx}"],
    css: false,
  },
}));
