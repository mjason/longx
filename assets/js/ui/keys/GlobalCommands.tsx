// The commands every page has (the space menu's top level and SPC p): the
// full key list (the palette registers its own ⌘K), settings, switching and creating projects,
// the theme, the reasoning's default, the conversation visited before and
// the next one waiting on the person.
import { useMatch, useNavigate } from "react-router";
import { toast } from "sonner";
import { listRunningThreads } from "@/core/api";
import { getPreference, setPreference } from "@/core/keys/preference";
import { useCommand } from "@/core/keys/useCommand";
import { previousVisit } from "@/core/keys/visits";
import { unwrap, useProjects, type FinishedThread, type RunningThread } from "@/core/projects";
import { setTheme } from "@/core/theme";
import { t } from "@/ui/strings";
import { openRunningPicker } from "./runningPicker";
import { updateKeysUi } from "./state";
import { setProjectPicker } from "@/core/projectNavigation";

export function GlobalCommands() {
  const navigate = useNavigate();
  const projects = useProjects();
  const threadId = useMatch("/p/:slug/t/:threadId")?.params.threadId ?? null;

  useCommand("help.keys", () => updateKeysUi({ help: true }));
  useCommand("settings.open", () => navigate("/settings"));
  useCommand("project.new", () => navigate("/new"));
  useCommand(
    "project.switch",
    () => setProjectPicker(true),
    () => (projects.data?.length ?? 0) > 0,
  );
  useCommand(
    "thread.last",
    () => {
      const before = previousVisit(threadId);
      if (before) navigate(`/p/${before.slug}/t/${before.id}`);
    },
    () => previousVisit(threadId) !== null,
  );
  // the next conversation that waits on the person (an ask), in any project; around again past the last
  useCommand("thread.waiting", () => {
    void listRunningThreads()
      .then(unwrap)
      .then((data) => {
        const waiting = (data.threads as RunningThread[]).filter((r) => r.waiting);
        if (waiting.length === 0) return void toast(t.keys.noWaiting);
        const at = waiting.findIndex((r) => r.id === threadId);
        const next = waiting[(at + 1) % waiting.length]!;
        if (next.id !== threadId) navigate(`/p/${next.projectSlug}/t/${next.id}`);
      })
      .catch((e: unknown) => toast.error(e instanceof Error ? e.message : String(e)));
  });
  // everything running now, any project, as a picker (the status strip's chip opens the same)
  useCommand("thread.running", () => {
    void listRunningThreads()
      .then(unwrap)
      .then((data) => {
        const threads = data.threads as RunningThread[];
        const finished = (data.finished ?? []) as FinishedThread[];
        if (threads.length === 0 && finished.length === 0) return void toast(t.keys.noRunning);
        openRunningPicker(threads, finished, threadId, navigate);
      })
      .catch((e: unknown) => toast.error(e instanceof Error ? e.message : String(e)));
  });
  useCommand("toggle.reasoning", () => setPreference("reasoningOpen", !getPreference("reasoningOpen")));
  useCommand("toggle.theme", () => setTheme(document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light"));
  return null;
}
