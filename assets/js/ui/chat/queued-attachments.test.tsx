import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { channel, failed, ok } from "@/ui/test-mocks";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { sendMessage, sendMessageBatch, steerTurn } from "@/core/api";

beforeEach(() => {
  localStorage.clear();
  _resetFrameStoreForTests();
  _resetWorkbenchForTests();
  channel.reset();
  vi.mocked(sendMessage).mockClear();
  vi.mocked(sendMessageBatch).mockClear();
  vi.mocked(steerTurn).mockClear();
});

async function openRunning() {
  renderAt("/p/app-1/t/t1");
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  act(() => channel.reply("ok", {
    thread_id: "thr_1",
    seq: 1,
    thread: { id: "thr_1" },
    turn: { id: "turn_1", status: "inProgress" },
    items: [{ id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "working" }] }],
    pending_requests: [],
  }));
  await screen.findByText("working");
}

function drop(file: File) {
  fireEvent.drop(document.querySelector("[data-slot=aui_composer-shell]")!, {
    dataTransfer: { files: [file], types: ["Files"] },
  });
}

test("two queued person messages run together with separate image and inline inputs", async () => {
  const user = userEvent.setup();
  await openRunning();
  drop(new File([new Uint8Array([137, 80, 78, 71])], "shot.png", { type: "image/png" }));
  await screen.findByRole("button", { name: /image attachment/i });
  await user.type(screen.getByRole("textbox", { name: "随心输入" }), "first instruction");
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  drop(new File(["file body"], "notes.txt", { type: "text/plain" }));
  await screen.findByRole("button", { name: /document attachment/i });
  await user.type(screen.getByRole("textbox", { name: "随心输入" }), "actually do this next");
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  act(() => channel.deliver("event", {
    seq: 2, method: "turn/completed", params: { turn: { id: "turn_1", status: "completed" } },
  }));
  await waitFor(() => expect(sendMessageBatch).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
    input: { threadId: "t1", messages: [
      { text: "first instruction", images: [expect.stringMatching(/^data:image\/png;base64,/)] },
      { text: expect.stringContaining("actually do this next"), images: [] },
    ] },
  })));
  const payload = vi.mocked(sendMessageBatch).mock.calls[0]![0]!.input! as { messages: { text: string }[] };
  expect(payload.messages[1]!.text).toContain("file body");
  expect(sendMessage).not.toHaveBeenCalled();
  expect(steerTurn).not.toHaveBeenCalled();
});

test("inserting a queued image-only message sends its image and echoes it", async () => {
  const user = userEvent.setup();
  await openRunning();
  drop(new File([new Uint8Array([137, 80, 78, 71])], "shot.png", { type: "image/png" }));
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  const queue = await screen.findByTestId("message-queue");
  expect(steerTurn).not.toHaveBeenCalled();
  let finish!: (value: never) => void;
  vi.mocked(steerTurn).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
  await user.click(within(queue).getByRole("button", { name: "插入" }));
  await waitFor(() => expect(steerTurn).toHaveBeenCalledWith(expect.objectContaining({
    input: { threadId: "t1", text: "", images: [expect.stringMatching(/^data:image\/png;base64,/)] },
  })));
  // Until the RPC succeeds, the queue and image echo both remain visible.
  expect(screen.getByTestId("message-queue")).toBeInTheDocument();
  expect(document.querySelector("img[src^='data:image/png']")).not.toBeNull();
  await act(async () => finish(ok({ kernelTurnId: "turn_1" }) as never));
  await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
  expect(sendMessage).not.toHaveBeenCalled();
});

test("insert preserves uploaded file paths, inline text and session delivery instructions", async () => {
  const user = userEvent.setup();
  const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    path: "/data/attachments/id-1/data.zip", name: "data.zip", bytes: 4,
  }), { status: 200 }));
  await openRunning();
  drop(new File([new Uint8Array([80, 75, 3, 4])], "data.zip", { type: "application/zip" }));
  await screen.findByRole("button", { name: /file attachment/i });
  await waitFor(() => expect(fetchMock).toHaveBeenCalled());
  drop(new File(["inline notes"], "notes.txt", { type: "text/plain" }));
  await screen.findByRole("button", { name: /document attachment/i });
  await user.type(screen.getByRole("textbox", { name: "随心输入" }), 'unpack @session("other:main")');
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  await user.click(within(await screen.findByTestId("message-queue")).getByRole("button", { name: "插入" }));
  await waitFor(() => expect(steerTurn).toHaveBeenCalledWith(expect.objectContaining({
    input: expect.objectContaining({
      threadId: "t1",
      text: expect.stringContaining('<attachment name="data.zip" path="/data/attachments/id-1/data.zip"'),
    }),
  })));
  const text = vi.mocked(steerTurn).mock.calls.at(-1)![0]!.input!.text;
  expect(text).toContain("inline notes");
  expect(text).toContain("成果接收会话");
  await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
  fetchMock.mockRestore();
});

test("not_running fallback keeps the queued image visible until the new send succeeds", async () => {
  const user = userEvent.setup();
  await openRunning();
  drop(new File([new Uint8Array([137, 80, 78, 71])], "shot.png", { type: "image/png" }));
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running") as never);
  let finish!: (value: never) => void;
  vi.mocked(sendMessage).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
  await user.click(within(await screen.findByTestId("message-queue")).getByRole("button", { name: "插入" }));
  await waitFor(() => expect(sendMessage).toHaveBeenCalled());
  expect(screen.queryByTestId("message-queue")).toBeInTheDocument();
  expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
    input: expect.objectContaining({ text: "", images: [expect.stringMatching(/^data:image\/png;base64,/)] }),
  }));
  await act(async () => finish(ok({ id: "new-turn" }) as never));
  await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
});

test("failed fallback reports its error and lets the original image be inserted again", async () => {
  const user = userEvent.setup();
  await openRunning();
  drop(new File([new Uint8Array([137, 80, 78, 71])], "shot.png", { type: "image/png" }));
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running") as never);
  vi.mocked(sendMessage).mockResolvedValueOnce(failed("暂时不可用") as never);
  await user.click(within(await screen.findByTestId("message-queue")).getByRole("button", { name: "插入" }));
  await screen.findByText(/暂时不可用/);
  const queue = screen.getByTestId("message-queue");
  await user.click(within(queue).getByRole("button", { name: "插入" }));
  await waitFor(() => expect(steerTurn).toHaveBeenCalledTimes(2));
  expect(steerTurn).toHaveBeenLastCalledWith(expect.objectContaining({
    input: expect.objectContaining({ text: "", images: [expect.stringMatching(/^data:image\/png;base64,/)] }),
  }));
  await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
});
