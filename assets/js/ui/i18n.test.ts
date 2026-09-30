import { afterEach, describe, expect, test } from "vitest";
import i18n from "@/core/i18n";
import { t } from "./strings";

afterEach(async () => {
  await i18n.changeLanguage("zh-CN");
  localStorage.clear();
});

describe("interface localization", () => {
  test("switches language and persists the explicit choice", async () => {
    localStorage.clear();
    await i18n.changeLanguage("en");

    expect(i18n.t("language")).toBe("Interface language");
    expect(t.noProjects).toBe("No projects yet");
    expect(t.dirty(1)).toBe("1 changed file");
    expect(localStorage.getItem("longx:language")).toBe("en");
  });

  test("provides the Simplified Chinese language label", async () => {
    await i18n.changeLanguage("zh-CN");
    expect(i18n.t("language")).toBe("界面语言");
    expect(t.noProjects).toBe("还没有项目");
    expect(t.dirty(2)).toBe("2 个文件有改动");
  });
});
