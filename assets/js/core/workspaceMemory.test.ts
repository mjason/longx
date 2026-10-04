import { beforeEach, expect, test } from "vitest";
import { _resetWorkspaceMemoryForTests, readFileDraft, readScroll, rememberFileDraft, rememberScroll, renameFileDraft } from "./workspaceMemory";

beforeEach(_resetWorkspaceMemoryForTests);

test("editing buffers are isolated by project, can be renamed, and only discarded explicitly", () => {
  rememberFileDraft("a", "README.md", "unsaved");
  expect(readFileDraft("b", "README.md")).toBeNull();
  renameFileDraft("a", "README.md", "intro.md");
  expect(readFileDraft("a", "intro.md")).toBe("unsaved");
  expect(readFileDraft("a", "README.md")).toBeNull();
  rememberFileDraft("a", "intro.md", null);
  expect(readFileDraft("a", "intro.md")).toBeNull();
});

test("a reading position and tail-following state are remembered separately for each conversation", () => {
  const viewport = document.createElement("div");
  Object.defineProperties(viewport, { scrollHeight: { value: 1000 }, clientHeight: { value: 300 } });
  viewport.scrollTop = 200;
  rememberScroll("a:t1", viewport);
  expect(readScroll("a:t1")).toEqual({ top: 200, following: false });
  expect(readScroll("b:t1")).toBeUndefined();
  viewport.scrollTop = 700;
  rememberScroll("a:t1", viewport);
  expect(readScroll("a:t1")).toEqual({ top: 700, following: true });
});
