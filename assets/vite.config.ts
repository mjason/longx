/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

// Phoenix serves the page and the built files under /assets (see
// LongxWeb.Vite); in dev the browser loads scripts straight from this
// server, so it must be reachable from the phone too (LONGX_DEV_HOST).
const devHost = process.env.LONGX_DEV_HOST;

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
  plugins: [react(), tailwindcss()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    include: ["js/**/*.test.{ts,tsx}"],
    css: false,
  },
}));
