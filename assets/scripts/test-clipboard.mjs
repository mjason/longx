// A real modal Radix menu on an insecure HTTP origin; no app server required.
import assert from "node:assert/strict";
import http from "node:http";
import { build } from "esbuild";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const bundle = await build({
  stdin: {
    resolveDir: root,
    loader: "tsx",
    contents: `
      import React from "react";
      import { createRoot } from "react-dom/client";
      import { DropdownMenu, ContextMenu } from "radix-ui";
      import { copyText } from "./js/ui/lib/clipboard";
      async function copy() {
        try { await copyText("/srv/app/lib"); window.result = "copied"; }
        catch { window.result = "failed"; }
      }
      const item = (Component) => <Component onSelect={copy}>Copy path</Component>;
      createRoot(document.getElementById("root")).render(<>
        <DropdownMenu.Root>
          <DropdownMenu.Trigger>More</DropdownMenu.Trigger>
          <DropdownMenu.Portal><DropdownMenu.Content>
            {item(DropdownMenu.Item)}
          </DropdownMenu.Content></DropdownMenu.Portal>
        </DropdownMenu.Root>
        <ContextMenu.Root>
          <ContextMenu.Trigger><div>Folder</div></ContextMenu.Trigger>
          <ContextMenu.Portal><ContextMenu.Content>
            {item(ContextMenu.Item)}
          </ContextMenu.Content></ContextMenu.Portal>
        </ContextMenu.Root>
      </>);
      const exec = document.execCommand.bind(document);
      document.execCommand = (command) => {
        window.selected = document.activeElement?.value;
        return exec(command);
      };
    `,
  },
  bundle: true,
  write: false,
  format: "iife",
  define: { "process.env.NODE_ENV": '"production"' },
});
const server = http.createServer((_req, res) => {
  res.setHeader("content-type", "text/html");
  res.end(`<div id="root"></div><script>${bundle.outputFiles[0].text}</script>`);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await chromium.launch({
  args: ["--host-resolver-rules=MAP longx.test 127.0.0.1", "--no-proxy-server"],
});
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`http://longx.test:${server.address().port}`);
  assert.equal(await page.evaluate(() => window.isSecureContext), false);
  assert.equal(await page.evaluate(() => typeof navigator.clipboard), "undefined");
  const origin = `http://localhost:${server.address().port}`;
  await page.context().grantPermissions(["clipboard-read"], { origin });
  const reader = await page.context().newPage();
  await reader.goto(origin);
  for (const kind of ["more", "context"]) {
    await page.evaluate(() => { window.result = null; window.selected = null; });
    if (kind === "more") await page.getByRole("button", { name: "More" }).click();
    else await page.getByText("Folder", { exact: true }).click({ button: "right" });
    await page.getByRole("menuitem", { name: "Copy path" }).click();
    await page.waitForFunction(() => window.result !== null);
    assert.equal(await page.evaluate(() => window.result), "copied", kind);
    assert.equal(await page.evaluate(() => window.selected), "/srv/app/lib", kind);
    assert.equal(await reader.evaluate(() => navigator.clipboard.readText()), "/srv/app/lib", kind);
    assert.equal(await page.locator("textarea").count(), 0);
  }
  console.log("HTTP clipboard: dropdown and context-menu selection copying passed");
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
