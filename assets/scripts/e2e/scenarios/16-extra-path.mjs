// The Agent Kernel's extra PATH is editable, saved globally and can return to
// the browser directory default. Restore the machine's original setting.
import { expect } from "../lib.mjs";

export async function run(h) {
  const fields = ["extraPath", "defaultExtraPath"];
  const initial = await h.rpc("agent_settings", {}, fields);

  try {
    await h.open(h.page, "/settings/agent");
    const settings = h.page.getByTestId("agent-settings");
    const path = settings.getByLabel("额外 PATH 目录");
    await path.waitFor();
    await path.fill("/tmp/longx-e2e-custom-bin");
    await settings.getByRole("button", { name: "保存" }).click();
    await h.page.getByText("已保存").waitFor();

    const saved = await h.rpc("agent_settings", {}, fields);
    expect(saved.extraPath === "/tmp/longx-e2e-custom-bin", `custom PATH persisted: ${JSON.stringify(saved)}`);

    await settings.getByRole("button", { name: "恢复默认" }).click();
    expect(await path.inputValue() === initial.defaultExtraPath, "reset uses the computed browser-directory default");
    await settings.getByRole("button", { name: "保存" }).click();
    await h.page.getByText("已保存").waitFor();

    const restored = await h.rpc("agent_settings", {}, fields);
    expect(
      restored.extraPath === initial.defaultExtraPath,
      `default PATH persisted: ${JSON.stringify(restored)}`,
    );
  } finally {
    await h.rpc("set_agent_settings", { extraPath: initial.extraPath }, fields);
  }
}
