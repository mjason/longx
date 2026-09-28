import { describe, expect, test, vi } from "vitest";
import type { AttachmentAdapter, PendingAttachment } from "@assistant-ui/react";
import { describeAttachmentError, reportingAdapter } from "./attachments";

const pending = (name: string): PendingAttachment => ({
  id: "a1",
  type: "document",
  name,
  contentType: "text/plain",
  file: new File(["x"], name, { type: "text/plain" }),
  status: { type: "requires-action", reason: "composer-send" },
});

// what FileReader hands `onerror`: a ProgressEvent whose target carries the DOMException
const readerFailure = (name: string) => {
  const event = new Event("error") as Event & { target: { error: { name: string; message: string } } };
  Object.defineProperty(event, "target", { value: { error: { name, message: "The requested file could not be read" } } });
  return event;
};

describe("attachments", () => {
  test("a file the browser could not read (FileReader's NotReadableError) is described for the person, by name; other failures keep their words", () => {
    expect(describeAttachmentError("notes.txt", readerFailure("NotReadableError"))).toBe(
      "浏览器读不了 notes.txt：选中后文件可能被改动、移动，或它所在的位置不允许读取（网络共享、云盘占位文件、正在被写入的文件）。换个位置或重新选一次。",
    );
    expect(describeAttachmentError("data.zip", new Error("上传失败（500）"))).toBe("data.zip：上传失败（500）");
    expect(describeAttachmentError("x.bin", "boom")).toBe("x.bin：boom");
    // an upload that never left the browser: fetch's own words say nothing (Chrome could
    // not open the file for the request body — net::ERR_ACCESS_DENIED — or the network is down)
    expect(describeAttachmentError("dump.txt", new TypeError("Failed to fetch"))).toBe(
      "dump.txt 没有上传出去：浏览器读不了这个文件（选中后被改动、移动，或它所在的位置不允许读取——网络共享、云盘占位文件、正在被写入的文件），或者网络断了。换个位置或重新选一次。",
    );
  });

  test("the reporting adapter tells the person when an add or a send fails, then lets the composer bounce the message as before", async () => {
    const inner: AttachmentAdapter = {
      accept: "*",
      add: vi.fn(async () => { throw new Error("上传失败（413）"); }),
      send: vi.fn(async () => { throw readerFailure("NotReadableError"); }),
      remove: vi.fn(async () => {}),
    };
    const report = vi.fn();
    const adapter = reportingAdapter(inner, report);
    expect(adapter.accept).toBe("*");

    await expect(adapter.add({ file: new File(["x"], "data.zip") })).rejects.toThrow("上传失败（413）");
    expect(report).toHaveBeenLastCalledWith("data.zip：上传失败（413）");

    await expect(adapter.send(pending("notes.txt"))).rejects.toBeDefined();
    expect(report).toHaveBeenLastCalledWith(expect.stringContaining("浏览器读不了 notes.txt"));

    await adapter.remove(pending("notes.txt"));
    expect(inner.remove).toHaveBeenCalled();
  });
});
