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
  /** the project's agent description changed on disk (`.longx/agent.exs`, its plugs, roles) → reread it */
  onDefinition?: () => void;
  /** HEAD, the index or a ref moved → the git window refetches */
  onGit?: () => void;
  /** the file watcher's state: while it watches, the tree follows the disk by itself */
  onWatch?: (status: WatchStatus) => void;
};

/** `watching` false: nothing follows the disk (the tree needs 刷新); `error` says why, or what could not be watched */
export type WatchStatus = { watching: boolean; error: string | null };

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
  channel.on("definition", () => handlers.onDefinition?.());
  channel.on("git", () => handlers.onGit?.());
  channel.on("watch", (payload: WatchStatus) => handlers.onWatch?.(payload));
  channel.join();
  return () => {
    channel.leave();
  };
}
