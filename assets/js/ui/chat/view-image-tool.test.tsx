import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, test } from "vitest";
import i18n from "@/core/i18n";
import { SurfaceContext } from "./toolkit";
import ViewImageTool from "./view-image-tool";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import type { ComponentProps } from "react";

function part(over: Partial<ToolCallMessagePartProps> = {}) {
  return {
    type: "tool-call", toolCallId: "image-1", toolName: "view_image.view_image",
    args: { path: "/tmp/截图.png" }, argsText: "", status: { type: "complete" },
    result: { success: true, details: { name: "截图.png", path: "saved 图片.png", mime: "image/png", attachment: true, bytes: 1024 } },
    addResult: () => {}, resume: () => {}, respondToApproval: async () => {},
    ...over,
  } as ComponentProps<typeof ViewImageTool>;
}

function card(props = part()) {
  return <SurfaceContext.Provider value={{ projectId: "project-1", open: () => {} }}>
    <ViewImageTool {...props} />
  </SurfaceContext.Provider>;
}

afterEach(async () => { await act(async () => { await i18n.changeLanguage("zh-CN"); }); });

test("snapshot thumbnail, zoom and all controls update live between Chinese and English", async () => {
  await i18n.changeLanguage("zh-CN");
  render(card());
  expect(screen.getByText("查看了图片")).toBeInTheDocument();
  expect(screen.getByRole("img", { name: "截图.png" })).toHaveAttribute("src", "/files/project-1/_attachments/saved%20%E5%9B%BE%E7%89%87.png?inline=1");
  fireEvent.click(screen.getByRole("button", { name: "点击查看大图" }));
  expect(screen.getByRole("dialog", { name: "图片大图" })).toBeInTheDocument();
  await act(async () => { await i18n.changeLanguage("en"); });
  expect(screen.getByText("Viewed image")).toBeInTheDocument();
  expect(screen.getByRole("dialog", { name: "Zoomed image" })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Close zoomed image" }));
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Click to zoom image" })).toHaveFocus();
});

test("running, typed failures and historical calls without previews never render raw JSON", async () => {
  const { rerender } = render(card(part({ result: undefined, status: { type: "running" } })));
  expect(screen.getByText("正在查看图片")).toBeInTheDocument();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  rerender(card(part({ isError: true, result: { success: false, details: { error: "not_found" } } })));
  expect(screen.getByText("查看图片失败")).toBeInTheDocument();
  expect(screen.getByText("图片文件不存在")).toBeInTheDocument();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  await act(async () => { await i18n.changeLanguage("en"); });
  expect(screen.getByText("Image file not found")).toBeInTheDocument();
  for (const [error, text] of [["unsupported_image", "Unsupported image format"], ["too_large", "The image exceeds the 20 MB limit"]]) {
    rerender(card(part({ isError: true, result: { success: false, details: { error } } })));
    expect(screen.getByText(text!)).toBeInTheDocument();
  }
  rerender(card(part({ result: { success: true, contentItems: [{ type: "inputText", text: "attached /tmp/截图.png" }] } })));
  expect(screen.getByText("No image preview is available for this record")).toBeInTheDocument();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  expect(screen.queryByText(/contentItems|Used tool/)).not.toBeInTheDocument();
});

test("a deleted or invalid snapshot reports a localized load failure rather than a broken image", async () => {
  render(card());
  fireEvent.error(screen.getByRole("img"));
  expect(screen.getByText("图片预览无法加载，文件可能已被移除")).toBeInTheDocument();
  await act(async () => { await i18n.changeLanguage("en"); });
  await waitFor(() => expect(screen.getByText("The preview could not load; the file may have been removed")).toBeInTheDocument());
});

test("never use an arbitrary local argument or non-attachment metadata as a preview URL", () => {
  const { rerender } = render(card(part({ result: { success: true, details: { path: "/etc/private.png", mime: "image/png", attachment: false } } })));
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  rerender(<ViewImageTool {...part()} />);
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
});
