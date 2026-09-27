// The Longx Chrome extension (docs/browser-design.md §2): its own Vite build,
// apart from the SPA's — `npm run build:extension` in assets/. Two entries,
// the service worker and the popup, land flat and unhashed in
// priv/static/extension/unpacked/ next to the copied manifest and icons, so
// the directory is what chrome://extensions loads unpacked and what the zip
// is made of.
import path from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  root: path.resolve(__dirname, "src"),
  publicDir: path.resolve(__dirname, "public"),
  // the popup is opened as chrome-extension://<id>/popup.html: its script
  // and stylesheet are referenced relatively, never from a site root
  base: "./",
  build: {
    outDir: path.resolve(__dirname, "../../priv/static/extension/unpacked"),
    emptyOutDir: true,
    target: "chrome118",
    // readable output: what the person loads unpacked is what they can read
    minify: false,
    modulePreload: { polyfill: false },
    rollupOptions: {
      input: {
        background: path.resolve(__dirname, "src/background.ts"),
        popup: path.resolve(__dirname, "src/popup.html"),
      },
      output: {
        format: "es",
        entryFileNames: "[name].js",
        chunkFileNames: "[name].js",
        assetFileNames: "[name][extname]",
      },
    },
  },
});
