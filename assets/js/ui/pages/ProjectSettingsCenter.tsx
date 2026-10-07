import { useOutletContext, useSearchParams } from "react-router";
import { useLayoutEffect, useRef } from "react";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { SettingsDraftProvider } from "./settings/SettingsDraft";
import { SettingsNavigation, useSettingsLabel, PROJECT_SECTIONS, GLOBAL_SECTIONS } from "./settings/SettingsNavigation";
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
  const knownSections = scope === "global" ? GLOBAL_SECTIONS : PROJECT_SECTIONS;
  const section = requested && knownSections.includes(requested) ? requested : (scope === "global" ? "models" : "project");
  const root = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const scroller = root.current?.closest<HTMLElement>('[data-testid="project-content"]');
    if (scroller) scroller.scrollTop = 0;
  }, [scope, section]);
  const href = (next: string) => `?scope=${scope}&section=${encodeURIComponent(next)}`;
  const changeScope = (next: string) => {
    const sections = next === "global" ? GLOBAL_SECTIONS : PROJECT_SECTIONS;
    setParams({
      scope: next,
      section: sections.includes(section) ? section : next === "global" ? "models" : "project",
    });
  };
  return (
    <div ref={root} className="relative flex min-h-0 flex-col" data-testid="settings-center">
      <header className="bg-background sticky top-0 z-10 border-b">
        <div className="mx-auto w-full max-w-6xl space-y-2 px-4 py-3 md:px-6">
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <h1 className="text-base font-semibold">{s.center}</h1>
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <span className="text-muted-foreground text-xs">{s.scope}</span>
          <div className="flex min-w-0 gap-1 rounded-lg bg-muted p-1" role="group" aria-label={s.scope}>
            <Button size="sm" variant="ghost" className={scope === "global" ? "bg-background text-primary shadow-sm hover:bg-background hover:text-primary" : "text-muted-foreground"} aria-pressed={scope === "global"} onClick={() => changeScope("global")}>{s.global}</Button>
            <Button size="sm" variant="ghost" className={`min-w-0 ${scope === "project" ? "bg-background text-primary shadow-sm hover:bg-background hover:text-primary" : "text-muted-foreground"}`} aria-pressed={scope === "project"} onClick={() => changeScope("project")}><span className="truncate">{s.project} · {ctx.name}</span></Button>
          </div>
        </div>
        </div>
        <p className="text-muted-foreground text-xs">{scope === "global" ? s.globalImpact : s.projectImpact}</p>
        </div>
      </header>
      <div className="mx-auto grid w-full max-w-6xl min-w-0 gap-5 p-4 md:grid-cols-[200px_minmax(0,1fr)] md:gap-8 md:p-6">
        <div className="min-w-0"><SettingsNavigation compact project={scope === "project"} active={section} href={href} /></div>
        <section className="min-w-0 space-y-5" data-testid="settings-detail" key={`${scope}-${section}`}>
          <h2 className="border-b pb-3 text-lg font-semibold">{label(section)}</h2>
          {scope === "project" ? <ProjectSettingsPage section={section} embedded /> :
            section === "diagnostics" ? <DiagnosticsSection /> : <SectionBody section={section} />}
        </section>
      </div>
    </div>
  );
}
