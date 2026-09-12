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

export type ProjectChannelHandlers = {
  onChanged?: () => void;
  onCodex?: (status: CodexStatus) => void;
  onSample?: (sample: CodexSample) => void;
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
  channel.join();
  return () => {
    channel.leave();
  };
}
