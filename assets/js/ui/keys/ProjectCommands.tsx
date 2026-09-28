// The space menu's commands inside a project window: the conversation
// (SPC a, SPC t), files and Git (SPC f, SPC g), the tool windows (SPC w),
// jumps in the thread (SPC j) — each registered with what can run it now, so
// the which-key panel offers only that. The tabs' own commands live in the
// Workbench, the editor's and the diff's in their tabs, the Git window's and
// the file tree's are reached through intents (core/keys/intents).
import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useMatch, useNavigate } from "react-router";
import { toast } from "sonner";
import { archiveThread, compactThread, renameThread, searchFiles } from "@/core/api";
import { useModelAliases, useModelRows } from "@/core/ai";
import { stoppedTurn } from "@/core/chat/stopped";
import { useFrame, type Tool } from "@/core/frame";
import { requestIntent } from "@/core/keys/intents";
import { openPicker } from "@/core/keys/picker";
import { openPrompt } from "@/core/keys/prompt";
import { useCommand } from "@/core/keys/useCommand";
import { queryKeys, unwrap, useGitInfo, useThreads } from "@/core/projects";
import { tabKey, useWorkbench } from "@/core/workbench";
import { useGitActions } from "@/core/workspace";
import { useChat } from "@/ui/chat/ChatProvider";
import { agentSummaries } from "@/ui/chat/AgentsPanel";
import { useGoalDialog } from "@/ui/chat/GoalBar";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";
import { whenThere } from "./whenThere";

const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

const composer = () => document.querySelector<HTMLTextAreaElement>(".aui-composer-input");
const viewport = () => document.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]');
const lastIn = (selector: string) => {
  const all = viewport()?.querySelectorAll<HTMLElement>(selector);
  return all && all.length > 0 ? all[all.length - 1]! : null;
};
const pendingAsk = () => lastIn('[data-testid="tool-action"]');
const lastError = () => lastIn('[data-failed], [data-testid="model-failed"], [role="alert"]');

export function ProjectCommands({ ctx }: { ctx: ProjectContext }) {
  const chat = useChat();
  const wb = useWorkbench(ctx.id);
  const frame = useFrame();
  const navigate = useNavigate();
  const client = useQueryClient();
  const git = useGitActions(ctx.id);
  const gitInfo = useGitInfo(ctx.id);
  const goal = useGoalDialog();
  const aliases = useModelAliases();
  const rows = useModelRows();
  const threads = useThreads(ctx.id);
  const settingsPage = useMatch("/p/:slug/settings") !== null;
  const lastTool = useRef<Tool>(frame.tool ?? "threads");
  useEffect(() => {
    if (frame.tool) lastTool.current = frame.tool;
  }, [frame.tool]);

  const thread = chat.thread;
  const inChat = !settingsPage;
  const repo = gitInfo.data?.repository === true;
  const toChat = () => wb.activate("chat");

  // ---- the conversation: SPC SPC, SPC a ----------------------------------

  useCommand(
    "ai.focus",
    () => {
      toChat();
      whenThere(composer, (el) => el.focus());
    },
    () => inChat && !chat.disabledReason,
  );
  useCommand("turn.stop", () => chat.runtime.thread.cancelRun(), () => chat.state === "running" || chat.state === "waiting");
  useCommand("turn.continue", () => void chat.sendText(t.continueText), () => chat.state === "idle" && stoppedTurn(chat.view) !== null);
  useCommand(
    "turn.discard",
    () => {
      const stopped = stoppedTurn(chat.view);
      if (stopped?.discardable) void chat.discardTurn(stopped.turnId);
    },
    () => chat.state === "idle" && stoppedTurn(chat.view)?.discardable === true,
  );
  useCommand("thread.new", () => navigate(`/p/${ctx.slug}`), () => inChat && thread !== undefined);
  useCommand(
    "thread.compact",
    () => {
      if (!thread) return;
      void compactThread({ input: { threadId: thread.id } })
        .then(unwrap)
        .then(() => toast.success(t.keys.compacted), fail);
    },
    () => thread !== undefined && chat.state === "idle",
  );
  useCommand("goal.open", () => goal?.open(), () => inChat && goal !== null && thread !== undefined);

  // the model in force now: the pick, the thread's, the description's, else the base row
  const modelName = chat.model ?? thread?.modelSlug ?? chat.definitionModel?.model ?? null;
  const alias = modelName ? aliases.data?.find((a) => a.name.toLowerCase() === modelName.toLowerCase()) : undefined;
  const modelSlug = alias ? alias.models[0] : (modelName ?? rows.data?.find((r) => r.default)?.slug);
  const levels = rows.data?.find((r) => r.slug === modelSlug)?.reasoningLevels ?? [];

  useCommand(
    "model.pick",
    () =>
      openPicker({
        title: t.keys.pickModel,
        items: [
          { id: "", label: t.keys.defaultModel },
          ...(aliases.data ?? []).map((a) => ({ id: a.name, label: a.label ? `${a.name} · ${a.label}` : a.name, detail: a.models.join(" → ") })),
          ...(rows.data ?? [])
            .filter((r) => typeof r.slug === "string" && r.slug !== "")
            .map((r) => ({ id: String(r.slug), label: String(r.slug), detail: r.name ?? "" })),
        ],
        onPick: (item) => chat.setModel(item.id === "" ? null : item.id),
      }),
    () => inChat && !chat.disabledReason && (rows.data?.length ?? 0) > 0,
  );
  useCommand(
    "effort.pick",
    () =>
      openPicker({
        title: t.keys.pickEffort,
        items: [{ id: "", label: t.keys.defaultEffort }, ...levels.map((l) => ({ id: l, label: l }))],
        onPick: (item) => chat.setEffort(item.id === "" ? null : item.id),
      }),
    () => inChat && !chat.disabledReason && levels.length > 0,
  );
  useCommand(
    "waiting.release",
    () => {
      const first = chat.view.waiting.items[0];
      if (first) void chat.releaseWaiting(first.id).catch(fail);
    },
    () => chat.view.waiting.items.length > 0,
  );
  const openAsk = () => {
    toChat();
    whenThere(pendingAsk, (el) => {
      el.scrollIntoView({ block: "center" });
      el.querySelector<HTMLElement>("button, input, textarea")?.focus();
    });
  };
  useCommand("ask.open", openAsk, () => inChat && chat.view.requests.length > 0);

  // ---- conversations: SPC t -----------------------------------------------

  useCommand(
    "thread.switch",
    () =>
      openPicker({
        title: t.keys.switchThread,
        items: (threads.data ?? []).map((r) => ({
          id: r.id,
          label: r.title || r.preview || `~${r.id.slice(-6)}`,
          ...(r.lastActivityAt ? { detail: new Date(r.lastActivityAt).toLocaleString() } : {}),
          keywords: r.preview ?? "",
        })),
        onPick: (item) => navigate(`/p/${ctx.slug}/t/${item.id}`),
      }),
    () => (threads.data?.length ?? 0) > 0,
  );
  useCommand(
    "thread.rename",
    () => {
      if (!thread) return;
      openPrompt({
        title: t.keys.renameThread,
        label: t.keys.renameLabel,
        value: thread.title ?? "",
        submit: t.keys.rename,
        onSubmit: (title) =>
          void renameThread({ identity: thread.id, input: { title } })
            .then(unwrap)
            .then(() => {
              void client.invalidateQueries({ queryKey: queryKeys.threads(ctx.id) });
              toast.success(t.keys.renamed);
            }, fail),
      });
    },
    () => thread !== undefined,
  );
  useCommand(
    "thread.archive",
    () => {
      if (!thread) return;
      void archiveThread({ identity: thread.id })
        .then(unwrap)
        .then(() => {
          void client.invalidateQueries({ queryKey: queryKeys.threads(ctx.id) });
          toast.success(t.keys.archived);
          navigate(`/p/${ctx.slug}`);
        }, fail);
    },
    () => thread !== undefined && chat.state === "idle",
  );
  useCommand("subagents.open", () => frame.open("agents"));

  // ---- files: SPC f -----------------------------------------------------------

  useCommand(
    "file.find",
    () =>
      openPicker({
        title: t.keys.findFile,
        placeholder: t.keys.findFilePlaceholder,
        search: async (query) => {
          if (query.trim() === "") return [];
          const found = unwrap(await searchFiles({ input: { id: ctx.id, query } })) as { path: string }[];
          return found.map((f) => ({ id: f.path, label: f.path.split("/").at(-1) ?? f.path, detail: f.path }));
        },
        onPick: (item) => wb.open({ kind: "file", path: item.id }),
      }),
    () => !settingsPage,
  );
  useCommand("files.open", () => frame.open("files"));
  const activeTab = wb.tabs.find((tab) => tabKey(tab) === wb.active);
  const activePath = activeTab && (activeTab.kind === "file" || activeTab.kind === "diff") ? activeTab.path : null;
  useCommand(
    "file.reveal",
    () => {
      if (!activePath) return;
      frame.open("files");
      requestIntent("files.reveal", activePath);
    },
    () => activePath !== null,
  );

  // ---- Git: SPC g -------------------------------------------------------------

  useCommand("git.open", () => frame.open("git"));
  useCommand(
    "git.commit",
    () => {
      frame.open("git");
      requestIntent("git.commit");
    },
    () => repo,
  );
  useCommand("git.push", () => git.push.mutate(undefined, { onSuccess: () => toast.success(t.keys.pushed), onError: fail }), () => repo && !git.push.isPending);
  useCommand("git.pull", () => git.pull.mutate(undefined, { onSuccess: () => toast.success(t.keys.pulled), onError: fail }), () => repo && !git.pull.isPending);
  useCommand(
    "git.history",
    () => {
      frame.open("git");
      requestIntent("git.history");
    },
    () => repo,
  );
  useCommand(
    "git.branches",
    () => {
      frame.open("git");
      requestIntent("git.branches");
    },
    () => repo,
  );

  // ---- tool windows: SPC w ------------------------------------------------------

  useCommand("tool.threads", () => frame.toggle("threads"));
  useCommand("tool.git", () => frame.toggle("git"));
  useCommand("tool.agents", () => frame.toggle("agents"));
  useCommand("tool.files", () => frame.toggle("files"));
  useCommand("tool.toggle", () => (frame.tool ? frame.close() : frame.open(lastTool.current)));
  useCommand("agents.panel", () => requestIntent("agents.panel"), () => inChat && agentSummaries(chat.view, chat.subviews).length > 0);

  // ---- the project, jumps: SPC p s, SPC j -----------------------------------------

  useCommand("project.settings", () => navigate(`/p/${ctx.slug}/settings`), () => !settingsPage);
  useCommand(
    "jump.bottom",
    () => {
      toChat();
      whenThere(viewport, (el) => el.scrollTo({ top: el.scrollHeight }));
    },
    () => inChat,
  );
  useCommand("jump.ask", openAsk, () => inChat && chat.view.requests.length > 0);
  useCommand(
    "jump.error",
    () => {
      toChat();
      whenThere(lastError, (el) => el.scrollIntoView({ block: "center" }));
    },
    () => inChat && lastError() !== null,
  );

  return null;
}
