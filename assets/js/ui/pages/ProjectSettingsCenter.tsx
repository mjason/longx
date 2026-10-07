import { useOutletContext, useSearchParams } from "react-router";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { SettingsDraftProvider } from "./settings/SettingsDraft";
import { SettingsNavigation, useSettingsLabel, PROJECT_SECTIONS, GLOBAL_GROUPS, PROJECT_GROUPS } from "./settings/SettingsNavigation";
import { useSettingsCopy } from "./settings/copy";
import { ProjectSettingsPage } from "./ProjectSettingsPage";
import { DiagnosticsSection, SectionBody } from "./SettingsPage";
import { Button } from "@/ui/components/ui/button";

export function ProjectSettingsCenter() {
  return <SettingsDraftProvider><Center /></SettingsDraftProvider>;
}

function Center() {
  const ctx = useOutletContext<ProjectContext>();
  const [params, setParams] = useSearchParams();
  const s = useSettingsCopy();
  const label = useSettingsLabel();
  const scope = params.get("scope") === "global" ? "global" : "project";
  const requested = params.get("section");
  const knownSections: readonly string[] = [...GLOBAL_GROUPS, ...PROJECT_GROUPS].flatMap((group) => [...group.sections]);
  const section = requested && knownSections.includes(requested) ? requested : (scope === "global" ? "models" : "project");
  const href = (next: string) => `?scope=${scope}&section=${encodeURIComponent(next)}`;
  const changeScope = (next: string) => setParams({
    scope: next,
    section: next === "project" && section === "models" ? "project" : next === "global" && section === "project" ? "models" : section,
  });
  return (
    <div className="flex min-h-0 flex-col" data-testid="settings-center">
      <header className="bg-background sticky top-0 z-10 space-y-3 border-b p-4">
        <div className="flex flex-wrap items-center justify-between gap-2"><h1 className="text-lg font-medium">{s.center}</h1><span className="text-muted-foreground text-xs">{ctx.name}</span></div>
        <div className="flex flex-wrap items-center gap-3">
          <span className="text-muted-foreground text-xs">{s.scope}</span>
          <div className="flex gap-1 rounded-lg bg-muted p-1" role="group" aria-label={s.scope}>
            <Button size="sm" variant={scope === "global" ? "secondary" : "ghost"} aria-pressed={scope === "global"} onClick={() => changeScope("global")}>{s.global}</Button>
            <Button size="sm" variant={scope === "project" ? "secondary" : "ghost"} aria-pressed={scope === "project"} onClick={() => changeScope("project")}>{s.project} · {ctx.name}</Button>
          </div>
        </div>
        <p className="text-muted-foreground text-xs">{scope === "global" ? s.globalImpact : s.projectImpact}</p>
      </header>
      <div className="grid min-w-0 gap-4 p-4 md:grid-cols-[190px_minmax(0,1fr)]">
        <div className="min-w-0"><SettingsNavigation compact project={scope === "project"} active={section} href={href} /></div>
        <section className="min-w-0 space-y-4" key={`${scope}-${section}`}>
          <h2 className="text-lg font-medium">{label(section)}</h2>
          {section === "diagnostics" ? <DiagnosticsSection projectId={scope === "project" ? ctx.id : undefined} /> :
            scope === "project" && PROJECT_SECTIONS.includes(section) ? <ProjectSettingsPage section={section} /> :
            scope === "project" || ["project", "extensions"].includes(section) ? (
              <div className="space-y-3 rounded-lg border p-4">
                <p className="text-muted-foreground text-sm">{scope === "project" ? s.globalOnly : s.projectOnly}</p>
                <Button onClick={() => changeScope(scope === "project" ? "global" : "project")}>{scope === "project" ? s.editGlobal : s.project}</Button>
              </div>
            ) : <SectionBody section={section} />}
        </section>
      </div>
    </div>
  );
}
