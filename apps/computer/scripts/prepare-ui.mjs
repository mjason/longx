import { readFile, writeFile } from "node:fs/promises";

// Reuse Longx's source tokens without shipping Tailwind or the web client.
const source = await readFile(new URL("../../../assets/css/app.css", import.meta.url), "utf8");
const declarations = (selector) => {
  const start = source.indexOf(`${selector} {`);
  if (start < 0) throw new Error(`Missing Longx theme: ${selector}`);
  const body = source.slice(start + selector.length + 2);
  return body.slice(0, body.indexOf("}"));
};
const dark = declarations(":root");
const light = declarations('[data-theme="light"]');
await writeFile(new URL("../ui/theme.css", import.meta.url),
  `/* Generated from assets/css/app.css by prepare-ui.mjs. */\n:root {${dark}}\n` +
  `[data-theme="light"] {${light}}\n` +
  `@media (prefers-color-scheme: light) {\n:root:not([data-theme]) {${light}}\n}\n`);
