// A real turn on the configured model: a file is written and a command run;
// the page shows the person's message, a command row and the answer; the
// turn's badge carries its tokens. Then the same page on a phone.
import { expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(t.id, "在项目目录里新建 hello.py（打印 hello），然后运行它，最后只回答一句话。");
  const turns = await h.idle(t.id);
  expect(turns.length === 1 && turns[0].status === "completed", `turn: ${JSON.stringify(turns)}`);

  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  expect(await page.getByText("在项目目录里新建 hello.py").count(), "the person's message is on the page");
  expect((await page.getByTestId("tool-command").count()) >= 1, "a command row");
  expect((await page.getByText(/\d[\d.,]*k? tok/).count()) >= 1, "the turn's timing badge with its tokens");
  await h.shot(page, "desktop");
  await h.noOverflow(page, "turn desktop");

  const phone = await h.phone();
  await h.open(phone, `/p/${h.slug}/t/${t.id}`);
  await h.noOverflow(phone, "turn phone");
  await h.shot(phone, "phone");

  // a second turn goes out from the composer itself
  await page.getByRole("textbox", { name: "随心输入" }).fill("再回答一次：hello.py 打印了什么？只回答一个词。");
  await page.keyboard.press("Enter");
  const again = await h.idle(t.id, 180_000, 2);
  expect(again.length === 2 && again[1].status === "completed", `second turn: ${JSON.stringify(again)}`);
}
