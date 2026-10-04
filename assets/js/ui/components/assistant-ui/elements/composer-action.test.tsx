import type { ReactNode } from "react";
import { render, screen } from "@testing-library/react";
import { beforeEach, expect, test, vi } from "vitest";
import { ComposerAction } from "./thread.aui";
import { t } from "@/ui/strings";

const { state } = vi.hoisted(() => ({
  state: {
    thread: { isRunning: true, capabilities: { attachments: false, dictation: false } },
    composer: { text: "", isEmpty: true, canSend: false, attachments: [] as unknown[] },
  },
}));

vi.mock("@assistant-ui/react", async (original) => {
  const actual = await original<typeof import("@assistant-ui/react")>();
  const passthrough = ({ children }: { children: ReactNode }) => children;
  return {
    ...actual,
    useAuiState: (selector: (s: typeof state) => unknown) => selector(state),
    AuiIf: ({ condition, children }: { condition: (s: typeof state) => boolean; children: ReactNode }) =>
      condition(state) ? children : null,
    ComposerPrimitive: { ...actual.ComposerPrimitive, Send: passthrough, Cancel: passthrough },
  };
});

beforeEach(() => {
  state.thread.isRunning = true;
  state.composer.text = "";
  state.composer.isEmpty = true;
  state.composer.canSend = false;
  state.composer.attachments = [];
});

test.each(["image", "file"])("a running turn shows send for an attachment-only %s draft", (type) => {
  state.composer.attachments = [{ type, status: { type: "complete" } }];
  state.composer.isEmpty = false;
  state.composer.canSend = true;
  render(<ComposerAction />);
  expect(screen.getByRole("button", { name: t.queueSend })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: t.stopTurn })).not.toBeInTheDocument();
});

test("a running turn with no draft still shows stop", () => {
  render(<ComposerAction />);
  expect(screen.getByRole("button", { name: t.stopTurn })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: t.queueSend })).not.toBeInTheDocument();
});
