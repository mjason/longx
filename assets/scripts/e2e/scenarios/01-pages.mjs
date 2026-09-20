// Every page opens without a console error and without horizontal overflow,
// on a desktop and on a phone.
import { expect } from "../lib.mjs";

const SETTINGS = ["models", "dependencies", "knowledge", "agent", "watches", "processes", "update", "requests", "appearance", "credentials"];

export async function run(h) {
  await h.project();
  const phone = await h.phone();
  for (const [page, label] of [[h.page, "desktop"], [phone, "phone"]]) {
    for (const p of ["/", "/new", `/p/${h.slug}`, `/p/${h.slug}/settings`, ...SETTINGS.map((s) => `/settings/${s}`)]) {
      await h.open(page, p);
      await h.noOverflow(page, `${label} ${p}`);
      expect((await page.title()).length > 0, `${p}: no title`);
    }
    await h.shot(page, `${label}-settings`);
  }
}
