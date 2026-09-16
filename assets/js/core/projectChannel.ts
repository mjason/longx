// `project:<id>` — the signals a project page needs besides thread streams.
// See LongxWeb.ProjectChannel.
import type { Channel, Socket } from "phoenix";

export type CodexStatus = "ready" | "down";

export type CodexSample = {
  rss_bytes: number;
  processes: number;
  cpu_ms: number;
  uptime_ms: number;
  turns: number;
  active_turns: number;
};

/** a config warning or a deprecation notice from the project's codex */
export type CodexNotice = { kind: "configWarning" | "deprecationNotice" | string; summary: string; details: string | null };

export type ProjectChannelHandlers = {
  onChanged?: () => void;
  onCodex?: (status: CodexStatus) => void;
  onSample?: (sample: CodexSample) => void;
  /** files changed under the project root (codex watches it for us) */
  onFiles?: (paths: string[]) => void;
  onNotice?: (notice: CodexNotice) => void;
};

/** Joins the project's channel; returns the function that leaves it. */
export function joinProjectChannel(
  socket: Pick<Socket, "channel">,
  projectId: string,
  handlers: ProjectChannelHandlers,
): () => void {
  const channel: Channel = socket.channel(`project:${projectId}`, {});
  channel.on("changed", () => handlers.onChanged?.());
  channel.on("codex", (payload: { status: CodexStatus }) => handlers.onCodex?.(payload.status));
  channel.on("sample", (payload: CodexSample) => handlers.onSample?.(payload));
  channel.on("files", (payload: { paths: string[] }) => handlers.onFiles?.(payload.paths));
  channel.on("notice", (payload: CodexNotice) => handlers.onNotice?.(payload));
  channel.join();
  return () => {
    channel.leave();
  };
}
