// Every page opens without a console error and without horizontal overflow,
// on a desktop and on a phone.
import { expect } from "../lib.mjs";

const SETTINGS = ["models", "providers", "dependencies", "knowledge", "agent", "browsers", "https", "files", "watches", "processes", "update", "requests", "appearance", "credentials", "keys"];

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
    // Longer English labels must fit as well; restore the suite's language.
    await page.evaluate(() => localStorage.setItem("longx:language", "en"));
    for (const section of ["models", "https"]) {
      await h.open(page, `/settings/${section}`);
      await page.getByText(section === "models" ? "Tiers" : "DNS provider", { exact: true }).first().waitFor();
      await h.noOverflow(page, `${label} en ${section}`);
    }
    await page.evaluate(() => localStorage.setItem("longx:language", "zh-CN"));
  }
}
