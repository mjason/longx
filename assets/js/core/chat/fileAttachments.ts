// The composer's third attachment kind: a file that is neither an image
// (a data url to the model) nor text (inlined) — a zip, a PDF, a dataset.
// It is uploaded to the server as soon as it is picked (POST
// /attachments/:project_id, the same headers as the RPC calls) and the
// message names the path it landed on; the agent reads it from there (the
// sandbox sees `/` read-only). DOM-free apart from fetch/FormData, so a
// React Native client can reuse it with its own token.
import type { AttachmentAdapter, CompleteAttachment, PendingAttachment } from "@assistant-ui/react";
import { formatBytes } from "@/core/format";
import { authHeaders, transportUrl } from "@/core/transport";

export type FileUploadOptions = {
  projectId: string;
  /** where to post (default `/attachments/<projectId>` on the configured server) */
  url?: string;
};

type Stored = { path: string; name: string; bytes: number };

/** what the model reads about an attached file */
export function attachmentLine(name: string, path: string, bytes: number): string {
  return `<attachment name="${name}" path="${path}" size="${formatBytes(bytes)}" />（文件已存到服务器上的这个路径，需要时直接读取或解压）`;
}

export class FileUploadAttachmentAdapter implements AttachmentAdapter {
  // everything: the composite adapter tries the image and text adapters first
  accept = "*";
  private stored = new Map<string, Stored>();

  constructor(private readonly opts: FileUploadOptions) {}

  async add({ file }: { file: File }): Promise<PendingAttachment> {
    const id = `file-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const body = new FormData();
    body.append("file", file, file.name);
    // the page's CSRF token or the app's bearer, like every RPC call
    const response = await fetch(this.opts.url ?? transportUrl(`/attachments/${this.opts.projectId}`), {
      method: "POST",
      body,
      headers: authHeaders(),
      credentials: "same-origin",
    });
    const json = (await response.json().catch(() => ({}))) as Partial<Stored> & { error?: string };
    if (!response.ok || typeof json.path !== "string") {
      throw new Error(json.error ?? `上传失败（${response.status}）`);
    }
    this.stored.set(id, { path: json.path, name: json.name ?? file.name, bytes: json.bytes ?? file.size });
    return {
      id,
      type: "file",
      name: file.name,
      contentType: file.type,
      file,
      status: { type: "requires-action", reason: "composer-send" },
    };
  }

  async send(attachment: PendingAttachment): Promise<CompleteAttachment> {
    const stored = this.stored.get(attachment.id);
    if (!stored) throw new Error(`附件 ${attachment.name} 没有上传成功`);
    return {
      ...attachment,
      status: { type: "complete" },
      content: [{ type: "text", text: attachmentLine(stored.name, stored.path, stored.bytes) }],
    };
  }

  async remove(attachment: { id: string }): Promise<void> {
    this.stored.delete(attachment.id);
  }
}
