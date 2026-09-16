import { afterEach, describe, expect, test, vi } from "vitest";
import { configureTransport, resetTransport } from "@/core/transport";
import { attachmentLine, FileUploadAttachmentAdapter } from "./fileAttachments";

const file = (name: string, type = "application/zip", size = 5) =>
  new File([new Uint8Array(size)], name, { type });

describe("FileUploadAttachmentAdapter (anything the image and text adapters do not take)", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    resetTransport();
    document.head.innerHTML = "";
  });

  test("accepts everything, so it must come last; add uploads at once and the tile waits for send", async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok">';
    const adapter = new FileUploadAttachmentAdapter({ projectId: "p1" });
    expect(adapter.accept).toBe("*");
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ path: "/data/attachments/p1/20260916T020000-data.zip", name: "data.zip", bytes: 5 }), { status: 200 }),
    );

    const pending = await adapter.add({ file: file("data.zip") });
    expect(pending).toMatchObject({ type: "file", name: "data.zip", contentType: "application/zip", status: { type: "requires-action", reason: "composer-send" } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("/attachments/p1");
    expect((init as RequestInit).method).toBe("POST");
    expect((init as RequestInit).headers).toMatchObject({ "X-CSRF-Token": "tok" });
    expect((init as RequestInit).body).toBeInstanceOf(FormData);

    // send names the server path for the model — nothing more goes over the wire
    const complete = await adapter.send(pending);
    expect(complete.status).toEqual({ type: "complete" });
    expect(complete.content).toEqual([{ type: "text", text: attachmentLine("data.zip", "/data/attachments/p1/20260916T020000-data.zip", 5) }]);
    expect(complete.content[0]).toMatchObject({ text: expect.stringContaining("/data/attachments/p1/20260916T020000-data.zip") });
  });

  test("a paired app uploads to its server with its bearer", async () => {
    configureTransport({ baseUrl: "http://10.0.0.5:7788", token: "dev" });
    const adapter = new FileUploadAttachmentAdapter({ projectId: "p1" });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ path: "/x/a.zip", name: "a.zip", bytes: 5 }), { status: 200 }),
    );
    await adapter.add({ file: file("a.zip") });
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("http://10.0.0.5:7788/attachments/p1");
    expect((init as RequestInit).headers).toEqual({ Authorization: "Bearer dev" });
  });

  test("an upload the server refuses is an error on the tile, with the server's words", async () => {
    const adapter = new FileUploadAttachmentAdapter({ projectId: "p1" });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ error: "no such project" }), { status: 404 }));
    await expect(adapter.add({ file: file("x.bin", "") })).rejects.toThrow(/no such project/);
  });

  test("remove forgets the upload; sending an attachment that never uploaded is refused", async () => {
    const adapter = new FileUploadAttachmentAdapter({ projectId: "p1" });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ path: "/p", name: "a.pdf", bytes: 1 }), { status: 200 }));
    const pending = await adapter.add({ file: file("a.pdf", "application/pdf", 1) });
    await adapter.remove(pending);
    await expect(adapter.send(pending)).rejects.toThrow();
  });
});
