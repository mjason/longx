// `project:<id>` — the signals a project page needs besides thread streams.
// See LongxWeb.ProjectChannel.
import type { Channel, Socket } from "phoenix";

export type ProjectChannelHandlers = {
  /** rows changed (threads, turns, sub-agents) → refetch */
  onChanged?: () => void;
  /** files changed under the project root */
  onFiles?: (paths: string[]) => void;
  /** the project's watches changed (a run began or ended, a file came or went) */
  onWatches?: () => void;
};

/** Joins the project's channel; returns the function that leaves it. */
export function joinProjectChannel(
  socket: Pick<Socket, "channel">,
  projectId: string,
  handlers: ProjectChannelHandlers,
): () => void {
  const channel: Channel = socket.channel(`project:${projectId}`, {});
  channel.on("changed", () => handlers.onChanged?.());
  channel.on("files", (payload: { paths: string[] }) => handlers.onFiles?.(payload.paths));
  channel.on("watches", () => handlers.onWatches?.());
  channel.join();
  return () => {
    channel.leave();
  };
}
