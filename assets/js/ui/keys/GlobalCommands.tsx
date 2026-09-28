// The commands every page has (the space menu's top level and SPC p): the
// palette, the full key list, settings, switching and creating projects,
// the theme, the reasoning's default.
import { useNavigate } from "react-router";
import { openPicker } from "@/core/keys/picker";
import { getPreference, setPreference } from "@/core/keys/preference";
import { useCommand } from "@/core/keys/useCommand";
import { useProjects } from "@/core/projects";
import { setTheme } from "@/core/theme";
import { t } from "@/ui/strings";
import { updateKeysUi } from "./state";

export function GlobalCommands() {
  const navigate = useNavigate();
  const projects = useProjects();

  useCommand("palette.open", () => updateKeysUi({ palette: true }));
  useCommand("help.keys", () => updateKeysUi({ help: true }));
  useCommand("settings.open", () => navigate("/settings"));
  useCommand("project.new", () => navigate("/new"));
  useCommand(
    "project.switch",
    () =>
      openPicker({
        title: t.keys.switchProject,
        items: (projects.data ?? []).map((p) => ({ id: p.slug, label: p.name, detail: p.rootPath, keywords: p.slug })),
        onPick: (item) => navigate(`/p/${item.id}`),
      }),
    () => (projects.data?.length ?? 0) > 0,
  );
  useCommand("toggle.reasoning", () => setPreference("reasoningOpen", !getPreference("reasoningOpen")));
  useCommand("toggle.theme", () => setTheme(document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light"));
  return null;
}
